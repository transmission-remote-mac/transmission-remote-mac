#!/usr/bin/env python3
# Transmission Remote Mac
# SPDX-FileCopyrightText: 2026 aidpok
# SPDX-License-Identifier: GPL-2.0-only
# See CREDITS.md for upstream attribution.

"""
Deterministic local Transmission RPC mock for visual validation.

It implements the parts of the Transmission RPC surface this app uses:
session-id challenge/retry, session-get, session-stats, torrent-get
(object and table format), torrent-add, session-set, torrent actions, and
queue actions. It also provides deterministic port-test and blocklist-update
maintenance fixtures. Generated scale fixtures, delta controls, an all-stopped
idle transition, and response delay are available for deterministic performance
validation. It never talks to a real Transmission daemon and never touches
downloaded files.
"""

from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import json
import os
import posixpath
import socket
import sys
import threading
import time
import unicodedata
import urllib.parse
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


BASE_TIME = 1_735_704_000  # 2025-01-01 12:00:00 UTC; fixed for deterministic rows.
DEFAULT_SESSION_ID = "transmission-remote-mac-mock-session"
DELTA_CONTROL_PATH = "/__mock__/delta"
STATE_CONTROL_PATH = "/__mock__/state"
GENERATED_TORRENT_COUNTS = (0, 100, 1_000)
LARGE_DETAIL_FILE_COUNT = 10_000
MAXIMUM_RPC_REQUEST_BYTES = 64 * 1_024 * 1_024
MAXIMUM_MUTATION_EVENT_COUNT = 256

JSON_RPC_METHODS = {
    "blocklist_update": "blocklist-update",
    "free_space": "free-space",
    "port_test": "port-test",
    "queue_move_bottom": "queue-move-bottom",
    "queue_move_down": "queue-move-down",
    "queue_move_top": "queue-move-top",
    "queue_move_up": "queue-move-up",
    "session_close": "session-close",
    "session_get": "session-get",
    "session_set": "session-set",
    "session_stats": "session-stats",
    "torrent_add": "torrent-add",
    "torrent_get": "torrent-get",
    "torrent_reannounce": "torrent-reannounce",
    "torrent_remove": "torrent-remove",
    "torrent_rename_path": "torrent-rename-path",
    "torrent_set": "torrent-set",
    "torrent_set_location": "torrent-set-location",
    "torrent_start": "torrent-start",
    "torrent_start_now": "torrent-start-now",
    "torrent_stop": "torrent-stop",
    "torrent_verify": "torrent-verify",
}

JSON_ARGUMENT_NAMES = {
    "alt_speed_down": "alt-speed-down",
    "alt_speed_enabled": "alt-speed-enabled",
    "alt_speed_time_begin": "alt-speed-time-begin",
    "alt_speed_time_day": "alt-speed-time-day",
    "alt_speed_time_enabled": "alt-speed-time-enabled",
    "alt_speed_time_end": "alt-speed-time-end",
    "alt_speed_up": "alt-speed-up",
    "bandwidth_priority": "bandwidthPriority",
    "blocklist_enabled": "blocklist-enabled",
    "blocklist_url": "blocklist-url",
    "cache_size_mib": "cache-size-mb",
    "delete_local_data": "delete-local-data",
    "dht_enabled": "dht-enabled",
    "download_dir": "download-dir",
    "download_queue_enabled": "download-queue-enabled",
    "download_queue_size": "download-queue-size",
    "download_limit": "downloadLimit",
    "download_limited": "downloadLimited",
    "files_unwanted": "files-unwanted",
    "files_wanted": "files-wanted",
    "honors_session_limits": "honorsSessionLimits",
    "idle_seeding_limit": "idle-seeding-limit",
    "idle_seeding_limit_enabled": "idle-seeding-limit-enabled",
    "incomplete_dir": "incomplete-dir",
    "incomplete_dir_enabled": "incomplete-dir-enabled",
    "ip_protocol": "ip-protocol",
    "lpd_enabled": "lpd-enabled",
    "peer_limit": "peer-limit",
    "peer_limit_global": "peer-limit-global",
    "peer_limit_per_torrent": "peer-limit-per-torrent",
    "peer_port": "peer-port",
    "peer_port_random_on_start": "peer-port-random-on-start",
    "pex_enabled": "pex-enabled",
    "port_forwarding_enabled": "port-forwarding-enabled",
    "priority_high": "priority-high",
    "priority_low": "priority-low",
    "priority_normal": "priority-normal",
    "queue_position": "queuePosition",
    "queue_stalled_enabled": "queue-stalled-enabled",
    "queue_stalled_minutes": "queue-stalled-minutes",
    "rename_partial_files": "rename-partial-files",
    "seed_queue_enabled": "seed-queue-enabled",
    "seed_queue_size": "seed-queue-size",
    "seed_idle_limit": "seedIdleLimit",
    "seed_idle_mode": "seedIdleMode",
    "seed_ratio_limit": "seedRatioLimit",
    "seed_ratio_limited": "seedRatioLimited",
    "seed_ratio_mode": "seedRatioMode",
    "sequential_download": "sequentialDownload",
    "sequential_download_from_piece": "sequentialDownloadFromPiece",
    "speed_limit_down": "speed-limit-down",
    "speed_limit_down_enabled": "speed-limit-down-enabled",
    "speed_limit_up": "speed-limit-up",
    "speed_limit_up_enabled": "speed-limit-up-enabled",
    "tracker_add": "trackerAdd",
    "tracker_list": "trackerList",
    "tracker_remove": "trackerRemove",
    "tracker_replace": "trackerReplace",
    "upload_limit": "uploadLimit",
    "upload_limited": "uploadLimited",
}

TORRENT_FIELD_NAMES = {
    "activityDate": "activity_date",
    "addedDate": "added_date",
    "announceResponse": "announce_response",
    "announceState": "announce_state",
    "bandwidthPriority": "bandwidth_priority",
    "bytesCompleted": "bytes_completed",
    "clientName": "client_name",
    "corruptEver": "corrupt_ever",
    "dateCreated": "date_created",
    "desiredAvailable": "desired_available",
    "doneDate": "done_date",
    "downloadDir": "download_dir",
    "downloadedEver": "downloaded_ever",
    "downloadLimit": "download_limit",
    "downloadLimited": "download_limited",
    "errorString": "error_string",
    "fileStats": "file_stats",
    "flagStr": "flag_str",
    "hashString": "hash_string",
    "hasAnnounced": "has_announced",
    "haveUnchecked": "have_unchecked",
    "haveValid": "have_valid",
    "isPrivate": "is_private",
    "isStalled": "is_stalled",
    "lastAnnounceResult": "last_announce_result",
    "lastAnnounceSucceeded": "last_announce_succeeded",
    "lastAnnounceTime": "last_announce_time",
    "leftUntilDone": "left_until_done",
    "magnetLink": "magnet_link",
    "maxConnectedPeers": "max_connected_peers",
    "metadataPercentComplete": "metadata_percent_complete",
    "nextAnnounceTime": "next_announce_time",
    "peersGettingFromUs": "peers_getting_from_us",
    "peersSendingToUs": "peers_sending_to_us",
    "percentDone": "percent_done",
    "percentComplete": "percent_complete",
    "pieceCount": "piece_count",
    "pieceSize": "piece_size",
    "queuePosition": "queue_position",
    "rateDownload": "rate_download",
    "rateToClient": "rate_to_client",
    "rateToPeer": "rate_to_peer",
    "rateUpload": "rate_upload",
    "recheckProgress": "recheck_progress",
    "secondsDownloading": "seconds_downloading",
    "secondsSeeding": "seconds_seeding",
    "sequentialDownload": "sequential_download",
    "sequentialDownloadFromPiece": "sequential_download_from_piece",
    "seedIdleLimit": "seed_idle_limit",
    "seedIdleMode": "seed_idle_mode",
    "seedRatioLimit": "seed_ratio_limit",
    "seedRatioMode": "seed_ratio_mode",
    "seederCount": "seeder_count",
    "leecherCount": "leecher_count",
    "downloadCount": "download_count",
    "sizeWhenDone": "size_when_done",
    "totalSize": "total_size",
    "trackerList": "tracker_list",
    "trackerStats": "tracker_stats",
    "uploadedEver": "uploaded_ever",
    "uploadLimit": "upload_limit",
    "uploadLimited": "upload_limited",
    "uploadRatio": "upload_ratio",
}
JSON_TORRENT_FIELD_NAMES = {wire: canonical for canonical, wire in TORRENT_FIELD_NAMES.items()}

SESSION_RESULT_NAMES = {
    "rpc-version": "rpc_version",
    "rpc-version-minimum": "rpc_version_minimum",
    "rpc-version-semver": "rpc_version_semver",
    "download-dir-free-space": "download_dir_free_space",
    **{canonical: wire for wire, canonical in JSON_ARGUMENT_NAMES.items()},
}

STATS_RESULT_NAMES = {
    "activeTorrentCount": "active_torrent_count",
    "pausedTorrentCount": "paused_torrent_count",
    "torrentCount": "torrent_count",
    "downloadSpeed": "download_speed",
    "uploadSpeed": "upload_speed",
    "current-stats": "current_stats",
    "cumulative-stats": "cumulative_stats",
    "uploadedBytes": "uploaded_bytes",
    "downloadedBytes": "downloaded_bytes",
    "filesAdded": "files_added",
    "sessionCount": "session_count",
    "secondsActive": "seconds_active",
}

STATUS_STOPPED = 0
STATUS_CHECK_WAIT = 1
STATUS_CHECKING = 2
STATUS_DOWNLOAD_WAIT = 3
STATUS_DOWNLOADING = 4
STATUS_SEED_WAIT = 5
STATUS_SEEDING = 6

SAFE_ACTION_METHODS = {
    "torrent-start",
    "torrent-start-now",
    "torrent-stop",
    "torrent-verify",
    "torrent-reannounce",
    "torrent-remove",
    "torrent-rename-path",
    "torrent-set",
    "torrent-set-location",
    "queue-move-top",
    "queue-move-up",
    "queue-move-down",
    "queue-move-bottom",
}

OBSERVED_MUTATION_METHODS = {
    "torrent-rename-path",
    "torrent-set-location",
    "torrent-verify",
}

ALL_TORRENT_FIELDS = [
    "id",
    "name",
    "status",
    "errorString",
    "announceResponse",
    "recheckProgress",
    "sizeWhenDone",
    "leftUntilDone",
    "rateDownload",
    "rateUpload",
    "downloadLimit",
    "downloadLimitMode",
    "downloadLimited",
    "uploadLimit",
    "uploadLimitMode",
    "uploadLimited",
    "maxConnectedPeers",
    "seedRatioMode",
    "seedRatioLimit",
    "seedIdleMode",
    "seedIdleLimit",
    "trackerStats",
    "trackers",
    "trackerList",
    "metadataPercentComplete",
    "percentDone",
    "totalSize",
    "peersSendingToUs",
    "seeders",
    "peersGettingFromUs",
    "leechers",
    "eta",
    "uploadRatio",
    "downloadedEver",
    "corruptEver",
    "uploadedEver",
    "addedDate",
    "doneDate",
    "activityDate",
    "downloadDir",
    "bandwidthPriority",
    "queuePosition",
    "secondsSeeding",
    "isPrivate",
    "labels",
    "files",
    "fileStats",
    "priorities",
    "wanted",
    "peers",
    "nextAnnounceTime",
    "hashString",
]


def tracker(
    tracker_id: int,
    announce: str,
    host: str,
    *,
    seeder_count: int,
    leecher_count: int,
    download_count: int = 0,
    ok: bool = True,
    message: str = "",
) -> dict[str, Any]:
    return {
        "id": tracker_id,
        "announce": announce,
        "scrape": announce.replace("/announce", "/scrape"),
        "host": host,
        "announceState": 2 if not ok else 1,
        "hasAnnounced": True,
        "lastAnnounceSucceeded": ok,
        "lastAnnounceResult": message,
        "lastAnnounceTime": BASE_TIME - 600,
        "nextAnnounceTime": BASE_TIME + 1_800 + tracker_id * 120,
        "seederCount": seeder_count,
        "leecherCount": leecher_count,
        "downloadCount": download_count,
    }


def file_row(name: str, length: int, completed: int) -> dict[str, Any]:
    return {"name": name, "length": length, "bytesCompleted": completed}


def file_stat(completed: int, wanted: bool, priority: int) -> dict[str, Any]:
    return {"bytesCompleted": completed, "wanted": wanted, "priority": priority}


def peer(index: int, progress: float, down: int, up: int) -> dict[str, Any]:
    address_octet = 20 + index if index <= 234 else 20 + index % 200
    return {
        "address": f"203.0.113.{address_octet}",
        "port": 51_413 + index,
        "clientName": ["Transmission 4.0.6", "qBittorrent 5.0", "libtorrent 2.0"][index % 3],
        "flagStr": ["D", "U", "E"][index % 3],
        "progress": progress,
        "rateToClient": down,
        "rateToPeer": up,
        "country": ["AU", "NZ", "US"][index % 3],
    }


def tracker_rows(torrent_id: int, tracker_list: str) -> list[dict[str, Any]]:
    urls = [line.strip() for line in tracker_list.splitlines() if line.strip()]
    return [
        {
            "id": torrent_id + index,
            "announce": announce,
            "scrape": announce.replace("/announce", "/scrape"),
        }
        for index, announce in enumerate(urls)
    ]


def ensure_torrent_properties(row: dict[str, Any]) -> None:
    torrent_id = int(row.get("id", 0))
    download_limited = bool(row.get("downloadLimited", torrent_id in {1, 4}))
    upload_limited = bool(row.get("uploadLimited", torrent_id in {1, 2, 5}))
    row.setdefault("downloadLimit", 800 + torrent_id * 200)
    row.setdefault("downloadLimitMode", 1 if download_limited else 0)
    row.setdefault("downloadLimited", download_limited)
    row.setdefault("uploadLimit", 100 + torrent_id * 50)
    row.setdefault("uploadLimitMode", 1 if upload_limited else 0)
    row.setdefault("uploadLimited", upload_limited)
    row.setdefault("maxConnectedPeers", 35 + torrent_id * 5)
    row.setdefault("seedRatioMode", (1, 0, 2)[(torrent_id - 1) % 3])
    row.setdefault("seedRatioLimit", 1.5 + torrent_id * 0.25)
    row.setdefault("seedIdleMode", (1, 2, 0)[(torrent_id - 1) % 3])
    row.setdefault("seedIdleLimit", 20 + torrent_id * 10)

    trackers = row.get("trackers")
    if "trackerList" not in row:
        row["trackerList"] = "\n".join(
            tracker["announce"]
            for tracker in trackers or []
            if isinstance(tracker, dict) and isinstance(tracker.get("announce"), str)
        )
    if not isinstance(trackers, list):
        row["trackers"] = tracker_rows(torrent_id, row["trackerList"])


def torrent(
    torrent_id: int,
    name: str,
    *,
    status: int,
    percent_done: float,
    total_size: int,
    left_until_done: int,
    rate_download: int = 0,
    rate_upload: int = 0,
    upload_ratio: float = 0.0,
    labels: list[str] | None = None,
    error: str = "",
    announce: str = "https://tracker.example.test/announce",
    host: str = "tracker.example.test",
    private: bool = False,
    metadata: float = 1.0,
    recheck: float = 0.0,
    queue: int = 0,
) -> dict[str, Any]:
    done = max(0, total_size - left_until_done)
    rows = [
        file_row(f"{name}/README.txt", 64_000, 64_000 if percent_done else 0),
        file_row(f"{name}/payload.bin", max(total_size - 64_000, 0), max(done - 64_000, 0)),
        file_row(f"{name}/extras/sample.nfo", 8_192, 8_192 if percent_done >= 1 else 0),
    ]
    stats = [
        file_stat(rows[0]["bytesCompleted"], True, 0),
        file_stat(rows[1]["bytesCompleted"], True, 1 if torrent_id % 2 else 0),
        file_stat(rows[2]["bytesCompleted"], torrent_id % 2 == 0, -1),
    ]
    tracker_stats = [
        tracker(
            torrent_id,
            announce,
            host,
            seeder_count=max(0, 20 - torrent_id),
            leecher_count=5 + torrent_id,
            download_count=100 + torrent_id,
            ok=not error,
            message=error,
        )
    ]
    row = {
        "id": torrent_id,
        "name": name,
        "status": status,
        "errorString": error,
        "announceResponse": error or "Tracker returned scrape data OK",
        "recheckProgress": recheck,
        "sizeWhenDone": total_size,
        "leftUntilDone": left_until_done,
        "rateDownload": rate_download,
        "rateUpload": rate_upload,
        "trackerStats": copy.deepcopy(tracker_stats),
        "trackers": [{"id": torrent_id, "announce": announce, "scrape": announce.replace("/announce", "/scrape")}],
        "metadataPercentComplete": metadata,
        "percentDone": percent_done,
        "totalSize": total_size,
        "peersSendingToUs": 3 if rate_download else 0,
        "seeders": max(0, 20 - torrent_id),
        "peersGettingFromUs": 2 if rate_upload else 0,
        "leechers": 5 + torrent_id,
        "eta": int(left_until_done / rate_download) if rate_download else -1,
        "uploadRatio": upload_ratio,
        "downloadedEver": done,
        "corruptEver": torrent_id * 1_024,
        "uploadedEver": int(total_size * upload_ratio),
        "addedDate": BASE_TIME - torrent_id * 86_400,
        "doneDate": BASE_TIME - torrent_id * 3_600 if percent_done >= 1 else 0,
        "activityDate": BASE_TIME - torrent_id * 120,
        "downloadDir": "/Users/Shared/TransmissionRemoteMock",
        "bandwidthPriority": 1 if torrent_id == 1 else 0,
        "queuePosition": queue,
        "secondsSeeding": 7_200 * torrent_id if status == STATUS_SEEDING else 0,
        "isPrivate": private,
        "labels": labels or [],
        "files": rows,
        "fileStats": stats,
        "priorities": [stat["priority"] for stat in stats],
        "wanted": [stat["wanted"] for stat in stats],
        "peers": [
            peer(torrent_id, min(1.0, percent_done + 0.15), rate_download // 3, rate_upload // 2),
            peer(torrent_id + 1, percent_done, rate_download // 4, rate_upload // 3),
        ],
        "nextAnnounceTime": tracker_stats[0]["nextAnnounceTime"],
        "hashString": hashlib.sha1(f"mock-{torrent_id}-{name}".encode("utf-8")).hexdigest(),
    }
    row["magnetLink"] = f"magnet:?xt=urn:btih:{row['hashString']}&dn={urllib.parse.quote(name)}"
    ensure_torrent_properties(row)
    return row


def default_session() -> dict[str, Any]:
    return {
        "version": "4.0.6 Mock",
        "rpc-version": 18,
        "download-dir": "/Users/Shared/TransmissionRemoteMock",
        "download-dir-free-space": 128 * 1024 * 1024 * 1024,
        "peer-port": 51_413,
        "port-forwarding-enabled": True,
        "encryption": "preferred",
        "speed-limit-down-enabled": False,
        "speed-limit-down": 1_000,
        "speed-limit-up-enabled": True,
        "speed-limit-up": 250,
        "peer-limit-global": 200,
        "peer-limit-per-torrent": 50,
        "peer-port-random-on-start": False,
        "pex-enabled": True,
        "dht-enabled": True,
        "seedRatioLimited": False,
        "seedRatioLimit": 2.0,
        "blocklist-enabled": False,
        "blocklist-url": "https://example.test/blocklist.gz",
        "alt-speed-enabled": False,
        "alt-speed-down": 80,
        "alt-speed-up": 40,
        "alt-speed-time-enabled": False,
        "alt-speed-time-begin": 540,
        "alt-speed-time-end": 1_020,
        "alt-speed-time-day": 127,
        "incomplete-dir-enabled": True,
        "incomplete-dir": "/Users/Shared/TransmissionRemoteMock/Incomplete",
        "rename-partial-files": True,
        "lpd-enabled": False,
        "cache-size-mb": 64,
        "idle-seeding-limit-enabled": False,
        "idle-seeding-limit": 30,
        "utp-enabled": True,
        "download-queue-enabled": True,
        "download-queue-size": 5,
        "seed-queue-enabled": True,
        "seed-queue-size": 3,
        "queue-stalled-enabled": True,
        "queue-stalled-minutes": 30,
    }


def default_torrents() -> list[dict[str, Any]]:
    return [
        torrent(
            1,
            "Ubuntu ISO - downloading",
            status=STATUS_DOWNLOADING,
            percent_done=0.42,
            total_size=3_221_225_472,
            left_until_done=1_868_310_773,
            rate_download=2_400_000,
            rate_upload=80_000,
            upload_ratio=0.15,
            labels=["linux", "active"],
            queue=0,
        ),
        torrent(
            2,
            "Fedora Workstation - seeding",
            status=STATUS_SEEDING,
            percent_done=1.0,
            total_size=2_147_483_648,
            left_until_done=0,
            rate_upload=450_000,
            upload_ratio=3.42,
            labels=["linux", "seed"],
            queue=1,
        ),
        torrent(
            3,
            "Archive collection - paused complete",
            status=STATUS_STOPPED,
            percent_done=1.0,
            total_size=734_003_200,
            left_until_done=0,
            upload_ratio=1.05,
            labels=["archive"],
            queue=2,
        ),
        torrent(
            4,
            "Magnet metadata - fetching",
            status=STATUS_DOWNLOADING,
            percent_done=0.0,
            total_size=1_073_741_824,
            left_until_done=1_073_741_824,
            rate_download=64_000,
            labels=["magnet"],
            metadata=0.35,
            queue=3,
        ),
        torrent(
            5,
            "Large dataset - checking",
            status=STATUS_CHECKING,
            percent_done=0.88,
            total_size=8_589_934_592,
            left_until_done=1_030_792_151,
            upload_ratio=0.0,
            labels=["verify"],
            recheck=0.58,
            queue=4,
        ),
        torrent(
            6,
            "Tracker error sample",
            status=STATUS_STOPPED,
            percent_done=0.27,
            total_size=1_610_612_736,
            left_until_done=1_175_747_297,
            labels=["error"],
            error="Could not connect to tracker",
            host="broken-tracker.example.test",
            announce="https://broken-tracker.example.test/announce",
            private=True,
            queue=5,
        ),
    ]


def generated_torrent(torrent_id: int) -> dict[str, Any]:
    status_cycle = (
        STATUS_DOWNLOADING,
        STATUS_SEEDING,
        STATUS_STOPPED,
        STATUS_DOWNLOAD_WAIT,
        STATUS_CHECKING,
        STATUS_SEED_WAIT,
    )
    status = status_cycle[(torrent_id - 1) % len(status_cycle)]
    complete = status in {STATUS_SEEDING, STATUS_SEED_WAIT}
    percent_done = 1.0 if complete else ((torrent_id * 37) % 100) / 100
    total_size = (512 + (torrent_id % 32) * 128) * 1024 * 1024
    left_until_done = 0 if complete else int(total_size * (1 - percent_done))
    active_download = status == STATUS_DOWNLOADING
    active_upload = status == STATUS_SEEDING
    return torrent(
        torrent_id,
        f"Generated torrent {torrent_id:04d}",
        status=status,
        percent_done=percent_done,
        total_size=total_size,
        left_until_done=left_until_done,
        rate_download=(torrent_id % 17 + 1) * 64_000 if active_download else 0,
        rate_upload=(torrent_id % 11 + 1) * 24_000 if active_upload else 0,
        upload_ratio=(torrent_id % 500) / 100,
        labels=[f"group-{torrent_id % 8}", "generated"],
        private=torrent_id % 3 == 0,
        recheck=((torrent_id * 13) % 100) / 100 if status == STATUS_CHECKING else 0,
        queue=torrent_id - 1,
    )


def generated_torrents(count: int) -> list[dict[str, Any]]:
    return [generated_torrent(torrent_id) for torrent_id in range(1, count + 1)]


def large_detail_torrent(torrent_id: int, queue: int) -> dict[str, Any]:
    file_length = 1_048_576
    total_size = LARGE_DETAIL_FILE_COUNT * file_length
    row = torrent(
        torrent_id,
        "Large file tree fixture",
        status=STATUS_DOWNLOADING,
        percent_done=0.5,
        total_size=total_size,
        left_until_done=total_size // 2,
        rate_download=4_194_304,
        rate_upload=262_144,
        upload_ratio=0.25,
        labels=["generated", "large-files"],
        queue=queue,
    )
    files: list[dict[str, Any]] = []
    stats: list[dict[str, Any]] = []
    for index in range(LARGE_DETAIL_FILE_COUNT):
        completed = file_length if index % 2 == 0 else 0
        files.append(
            file_row(
                f"Large file tree fixture/folder-{index // 100:03d}/file-{index:05d}.bin",
                file_length,
                completed,
            )
        )
        stats.append(file_stat(completed, index % 7 != 0, (index % 3) - 1))
    row["files"] = files
    row["fileStats"] = stats
    row["priorities"] = [stat["priority"] for stat in stats]
    row["wanted"] = [stat["wanted"] for stat in stats]
    return row


class MockState:
    def __init__(
        self,
        session: dict[str, Any],
        torrents: list[dict[str, Any]],
        session_id: str,
        *,
        recently_active_ids: list[int] | None = None,
        recently_removed_ids: list[int] | None = None,
        port_is_open: bool = True,
        blocklist_size: int = 65_536,
        mutation_failures: dict[str, list[str]] | None = None,
    ) -> None:
        if not isinstance(port_is_open, bool):
            raise ValueError("port open state must be a boolean")
        if isinstance(blocklist_size, bool) or not isinstance(blocklist_size, int) or blocklist_size < 0:
            raise ValueError("blocklist size must be a non-negative integer")
        self.lock = threading.RLock()
        self.session = session
        self.torrents = torrents
        for row in self.torrents:
            ensure_torrent_properties(row)
        self.session_id = session_id
        self.next_id = max([row["id"] for row in torrents], default=0) + 1
        self.added_sources: dict[str, int] = {}
        self.removal_events: list[dict[str, Any]] = []
        self.request_count = 0
        self.method_request_counts: dict[str, int] = {}
        self.recently_active_torrent_get_request_count = 0
        self.in_flight_requests = 0
        self.max_in_flight_requests = 0
        self.last_torrent_get_selector: Any = None
        self.last_torrent_get_field_count = 0
        self.last_torrent_get_request_bytes = 0
        self.last_torrent_rename: dict[str, Any] | None = None
        self.last_torrent_set_location: dict[str, Any] | None = None
        self.mutation_event_sequence = 0
        self.mutation_events: list[dict[str, Any]] = []
        self.active_verifications: dict[int, dict[str, Any]] = {}
        self.mutation_failures = self.validated_mutation_failures(mutation_failures or {})
        self.port_is_open = port_is_open
        self.last_port_test_protocol: str | None = None
        self.blocklist_size = blocklist_size
        self.blocklist_update_count = 0
        self.delta_generation = 0
        self.delta_controlled = recently_active_ids is not None or recently_removed_ids is not None
        self.recently_active_ids = set(recently_active_ids or [])
        self.recently_removed_ids = set(recently_removed_ids or [])
        overlap = self.recently_active_ids & self.recently_removed_ids
        if overlap:
            raise ValueError(f"ids cannot be both recently active and removed: {sorted(overlap)}")
        if self.recently_removed_ids:
            self.torrents = [
                row for row in self.torrents
                if row.get("id") not in self.recently_removed_ids
            ]
        self.validate_recently_active_ids()

    def sorted_torrents(self) -> list[dict[str, Any]]:
        return sorted(self.torrents, key=lambda row: (row.get("queuePosition", 0), row.get("id", 0)))

    def validate_recently_active_ids(self) -> None:
        available = {row.get("id") for row in self.torrents}
        unknown = self.recently_active_ids - available
        if unknown:
            raise ValueError(f"recently active ids are not present in the fixture: {sorted(unknown)}")

    def begin_request(
        self,
        method: str,
        arguments: dict[str, Any],
        request_bytes: int,
    ) -> None:
        with self.lock:
            self.request_count += 1
            self.method_request_counts[method] = self.method_request_counts.get(method, 0) + 1
            self.in_flight_requests += 1
            self.max_in_flight_requests = max(self.max_in_flight_requests, self.in_flight_requests)
            if method == "torrent-get":
                selector = arguments.get("ids")
                self.last_torrent_get_selector = copy.deepcopy(selector)
                if isinstance(selector, str) and selector in {"recently-active", "recently_active"}:
                    self.recently_active_torrent_get_request_count += 1
                fields = arguments.get("fields")
                self.last_torrent_get_field_count = len(fields) if isinstance(fields, list) else 0
                self.last_torrent_get_request_bytes = max(0, request_bytes)

    def end_request(self) -> None:
        with self.lock:
            self.in_flight_requests = max(0, self.in_flight_requests - 1)

    def mark_changed(self, torrent_ids: set[int] | list[int]) -> None:
        if not self.delta_controlled:
            return
        active_ids = {row["id"] for row in self.torrents}
        self.recently_active_ids.update(set(torrent_ids) & active_ids)
        self.recently_active_ids.difference_update(self.recently_removed_ids)

    def mark_removed(self, torrent_ids: set[int] | list[int]) -> None:
        if not self.delta_controlled:
            return
        removed = set(torrent_ids)
        self.recently_removed_ids.update(removed)
        self.recently_active_ids.difference_update(removed)

    def control_delta(self, payload: dict[str, Any]) -> dict[str, Any]:
        enabled = payload.get("enabled", True)
        if not isinstance(enabled, bool):
            raise ValueError("delta control enabled must be a boolean")
        mode = payload.get("mode", "replace")
        if mode not in {"replace", "merge"}:
            raise ValueError("delta control mode must be replace or merge")
        all_torrents_state = payload.get("allTorrentsState")
        if all_torrents_state is not None and all_torrents_state != "stopped":
            raise ValueError("delta control allTorrentsState must be stopped")
        changed = self.parse_control_ids(payload.get("changed", []), "changed")
        removed = self.parse_control_ids(payload.get("removed", []), "removed")
        if not enabled and (changed or removed or all_torrents_state is not None):
            raise ValueError("disabled delta control cannot include changes")

        active_ids = {row["id"] for row in self.torrents}
        if all_torrents_state == "stopped":
            changed.update(active_ids - removed)
        overlap = changed & removed
        if overlap:
            raise ValueError(f"delta ids cannot be both changed and removed: {sorted(overlap)}")

        unknown_changed = changed - active_ids
        if unknown_changed:
            raise ValueError(f"changed ids are not present in the fixture: {sorted(unknown_changed)}")

        self.delta_controlled = enabled
        if mode == "replace":
            self.recently_active_ids = set()
            self.recently_removed_ids = set()
        if enabled:
            self.recently_active_ids.update(changed)
            self.recently_removed_ids.update(removed)
            self.recently_active_ids.difference_update(removed)
            if removed:
                self.torrents = [row for row in self.torrents if row["id"] not in removed]
            if all_torrents_state == "stopped":
                self.active_verifications.clear()
                for row in self.torrents:
                    row["status"] = STATUS_STOPPED
                    row["rateDownload"] = 0
                    row["rateUpload"] = 0
                    row["recheckProgress"] = 0
                    row["eta"] = -1
        else:
            self.recently_active_ids.clear()
            self.recently_removed_ids.clear()

        self.delta_generation += 1
        if enabled:
            for row in self.torrents:
                if row["id"] in changed:
                    row["activityDate"] = BASE_TIME + self.delta_generation
        return self.control_snapshot()

    @staticmethod
    def parse_control_ids(value: Any, name: str) -> set[int]:
        if not isinstance(value, list) or not all(
            isinstance(item, int) and not isinstance(item, bool) and item > 0
            for item in value
        ):
            raise ValueError(f"delta control {name} must be an array of positive integer ids")
        return set(value)

    def control_snapshot(self) -> dict[str, Any]:
        stopped_torrent_count = sum(
            1 for row in self.torrents if row.get("status") == STATUS_STOPPED
        )
        return {
            "deltaControlled": self.delta_controlled,
            "deltaGeneration": self.delta_generation,
            "recentlyActiveIds": sorted(self.recently_active_ids),
            "recentlyRemovedIds": sorted(self.recently_removed_ids),
            "torrentCount": len(self.torrents),
            "stoppedTorrentCount": stopped_torrent_count,
            "allTorrentsStopped": stopped_torrent_count == len(self.torrents),
            "torrentDownloadRate": sum(
                max(0, int(row.get("rateDownload", 0))) for row in self.torrents
            ),
            "torrentUploadRate": sum(
                max(0, int(row.get("rateUpload", 0))) for row in self.torrents
            ),
            "activeVerificationCount": len(self.active_verifications),
            "requestCount": self.request_count,
            "methodRequestCounts": dict(sorted(self.method_request_counts.items())),
            "recentlyActiveTorrentGetRequestCount": self.recently_active_torrent_get_request_count,
            "inFlightRequests": self.in_flight_requests,
            "maxInFlightRequests": self.max_in_flight_requests,
            "lastTorrentGetSelector": copy.deepcopy(self.last_torrent_get_selector),
            "lastTorrentGetFieldCount": self.last_torrent_get_field_count,
            "lastTorrentGetRequestBytes": self.last_torrent_get_request_bytes,
            "torrentRenamePathRequestCount": self.method_request_counts.get("torrent-rename-path", 0),
            "lastTorrentRename": copy.deepcopy(self.last_torrent_rename),
            "lastTorrentSetLocation": copy.deepcopy(self.last_torrent_set_location),
            "mutationEvents": copy.deepcopy(self.mutation_events),
            "pendingMutationFailureCounts": {
                method: len(messages)
                for method, messages in sorted(self.mutation_failures.items())
                if messages
            },
            "portIsOpen": self.port_is_open,
            "lastPortTestProtocol": self.last_port_test_protocol,
            "blocklistSize": self.blocklist_size,
            "blocklistUpdateCount": self.blocklist_update_count,
        }

    @staticmethod
    def validated_mutation_failures(
        failures: dict[str, list[str]],
    ) -> dict[str, list[str]]:
        if not isinstance(failures, dict):
            raise ValueError("mutation failures must be a method-to-messages object")
        validated: dict[str, list[str]] = {}
        for method, messages in failures.items():
            if method not in OBSERVED_MUTATION_METHODS:
                raise ValueError(f"unsupported mutation failure method: {method}")
            if not isinstance(messages, list) or not all(
                isinstance(message, str) and message.strip()
                for message in messages
            ):
                raise ValueError("mutation failure messages must be non-empty strings")
            validated[method] = list(messages)
        return validated

    def begin_mutation(self, method: str, arguments: dict[str, Any]) -> int:
        self.mutation_event_sequence += 1
        operation_id = self.mutation_event_sequence
        event = {
            "operationId": operation_id,
            "method": method,
            "phase": "submitted",
            "ids": copy.deepcopy(arguments.get("ids")),
        }
        for key in ("location", "move", "path", "name"):
            if key in arguments:
                event[key] = copy.deepcopy(arguments[key])
        self.append_mutation_event(event)
        return operation_id

    def record_mutation_phase(
        self,
        operation_id: int,
        method: str,
        phase: str,
        *,
        error: str | None = None,
    ) -> None:
        event: dict[str, Any] = {
            "operationId": operation_id,
            "method": method,
            "phase": phase,
        }
        if error is not None:
            event["error"] = error
        self.append_mutation_event(event)

    def append_mutation_event(self, event: dict[str, Any]) -> None:
        self.mutation_events.append(event)
        if len(self.mutation_events) > MAXIMUM_MUTATION_EVENT_COUNT:
            del self.mutation_events[:-MAXIMUM_MUTATION_EVENT_COUNT]

    def take_mutation_failure(self, method: str) -> str | None:
        messages = self.mutation_failures.get(method)
        if not messages:
            return None
        message = messages.pop(0)
        if not messages:
            del self.mutation_failures[method]
        return message

    def begin_verification(
        self,
        rows: list[dict[str, Any]],
        operation_id: int,
    ) -> None:
        for row in rows:
            torrent_id = row["id"]
            previous = self.active_verifications.get(torrent_id)
            original_status = (
                previous["originalStatus"]
                if previous is not None
                else int(row.get("status", STATUS_STOPPED))
            )
            self.active_verifications[torrent_id] = {
                "operationId": operation_id,
                "originalStatus": original_status,
                "pollCount": 0,
            }
            row["status"] = STATUS_CHECKING
            row["recheckProgress"] = 0.12

    def advance_verifications(self, requested_rows: list[dict[str, Any]]) -> None:
        completed_operation_ids: set[int] = set()
        changed_ids: set[int] = set()
        rows_by_id = {row.get("id"): row for row in requested_rows}
        for torrent_id, verification in list(self.active_verifications.items()):
            row = rows_by_id.get(torrent_id)
            if row is None:
                continue

            changed_ids.add(torrent_id)
            verification["pollCount"] += 1
            if verification["pollCount"] == 1:
                row["status"] = STATUS_CHECKING
                row["recheckProgress"] = 0.56
                continue

            row["status"] = verification["originalStatus"]
            row["recheckProgress"] = 1.0
            completed_operation_ids.add(verification["operationId"])
            del self.active_verifications[torrent_id]

        for operation_id in sorted(completed_operation_ids):
            if any(
                verification["operationId"] == operation_id
                for verification in self.active_verifications.values()
            ):
                continue
            self.record_mutation_phase(operation_id, "torrent-verify", "completed")
        self.mark_changed(changed_ids)

    def port_test(self, arguments: dict[str, Any]) -> dict[str, Any]:
        if self.session.get("rpc-version", 0) < 5:
            raise ValueError("port-test requires RPC version 5 or newer")
        unexpected = set(arguments) - {"ip-protocol"}
        if unexpected:
            raise ValueError(f"port-test received unexpected arguments: {sorted(unexpected)}")
        protocol = arguments.get("ip-protocol")
        if "ip-protocol" in arguments:
            if protocol not in {"ipv4", "ipv6"}:
                raise ValueError("ip-protocol must be ipv4 or ipv6 when supplied")
            if self.session.get("rpc-version", 0) < 18:
                raise ValueError("protocol-specific port-test requires RPC version 18 or newer")
        self.last_port_test_protocol = protocol
        result: dict[str, Any] = {"port-is-open": self.port_is_open}
        if protocol is not None:
            result["ip-protocol"] = protocol
        return result

    def blocklist_update(self, arguments: dict[str, Any]) -> dict[str, Any]:
        if self.session.get("rpc-version", 0) < 5:
            raise ValueError("blocklist-update requires RPC version 5 or newer")
        if arguments:
            raise ValueError("blocklist-update does not accept arguments")
        self.blocklist_update_count += 1
        return {"blocklist-size": self.blocklist_size}

    def rename_torrent_path(
        self,
        arguments: dict[str, Any],
        *,
        operation_id: int | None = None,
    ) -> dict[str, Any]:
        identifier = self.rename_torrent_identifier(arguments.get("ids"))
        row = next(
            (
                candidate for candidate in self.torrents
                if candidate.get("id") == identifier or candidate.get("hashString") == identifier
            ),
            None,
        )
        if row is None:
            raise ValueError("torrent-rename-path torrent not found")

        path = self.rename_source_path(arguments.get("path"))
        name = self.rename_destination_name(arguments.get("name"))
        root_rename = path == row.get("name")
        prefix = f"{path}/"
        files = row.get("files", [])
        matching_file_names = {
            file_name
            for file in files
            if isinstance(file, dict)
            and isinstance((file_name := file.get("name")), str)
            and (file_name == path or file_name.startswith(prefix))
        }
        if not root_rename and not matching_file_names:
            raise ValueError("torrent-rename-path path not found")

        parent, separator, _ = path.rpartition("/")
        destination = f"{parent}/{name}" if separator else name
        destination_prefix = f"{destination}/"
        unaffected_file_names = {
            file_name
            for file in files
            if isinstance(file, dict)
            and isinstance((file_name := file.get("name")), str)
            and file_name not in matching_file_names
        }
        if destination != path and any(
            file_name == destination
            or file_name.startswith(destination_prefix)
            or destination.startswith(f"{file_name}/")
            for file_name in unaffected_file_names
        ):
            raise ValueError("torrent-rename-path destination already exists")

        renamed_file_names: list[str] = []
        for file in files:
            file_name = file.get("name") if isinstance(file, dict) else None
            if not isinstance(file_name, str):
                continue
            if file_name == path:
                renamed_file_names.append(destination)
            elif file_name.startswith(prefix):
                renamed_file_names.append(f"{destination}{file_name[len(path):]}")
            else:
                renamed_file_names.append(file_name)
        if len(renamed_file_names) != len(set(renamed_file_names)):
            raise ValueError("torrent-rename-path destination already exists")

        if operation_id is not None:
            self.record_mutation_phase(
                operation_id,
                "torrent-rename-path",
                "running",
            )
        if root_rename:
            row["name"] = name
        for file in files:
            file_name = file.get("name") if isinstance(file, dict) else None
            if not isinstance(file_name, str):
                continue
            if file_name == path:
                file["name"] = destination
            elif file_name.startswith(prefix):
                file["name"] = f"{destination}{file_name[len(path):]}"

        response = {"id": row["id"], "path": path, "name": name}
        self.last_torrent_rename = copy.deepcopy(response)
        self.mark_changed({row["id"]})
        return response

    @staticmethod
    def rename_torrent_identifier(ids_value: Any) -> int | str:
        identifiers = ids_value if isinstance(ids_value, list) else [ids_value]
        if len(identifiers) != 1:
            raise ValueError("torrent-rename-path requires exactly one torrent identifier")
        identifier = identifiers[0]
        valid_numeric_id = isinstance(identifier, int) and not isinstance(identifier, bool) and identifier > 0
        valid_hash = isinstance(identifier, str) and bool(identifier)
        if not valid_numeric_id and not valid_hash:
            raise ValueError("torrent-rename-path requires exactly one torrent identifier")
        return identifier

    @staticmethod
    def rename_source_path(value: Any) -> str:
        if not isinstance(value, str) or not value:
            raise ValueError("torrent-rename-path requires a non-empty path")
        components = value.split("/")
        if (
            value.startswith("/")
            or value.endswith("/")
            or "\\" in value
            or any(component in {"", ".", ".."} for component in components)
            or any(unicodedata.category(character) == "Cc" for character in value)
        ):
            raise ValueError("torrent-rename-path path must be a canonical relative path")
        return value

    @staticmethod
    def rename_destination_name(value: Any) -> str:
        if not isinstance(value, str) or not value:
            raise ValueError("torrent-rename-path name must be a non-empty single path component")
        if (
            value in {".", ".."}
            or "/" in value
            or "\\" in value
            or any(unicodedata.category(character) == "Cc" for character in value)
        ):
            raise ValueError("torrent-rename-path name must be a non-empty single path component")
        return value


class MockTransmissionHandler(BaseHTTPRequestHandler):
    server: "MockTransmissionServer"

    def setup(self) -> None:
        super().setup()
        self.connection.settimeout(self.server.client_io_timeout_seconds)

    def log_message(self, fmt: str, *args: Any) -> None:
        if self.server.verbose:
            super().log_message(fmt, *args)

    def do_GET(self) -> None:
        if self.path in {"/", "/health"}:
            if not self.authorized():
                self.write_unauthorized()
                return
            with self.server.state.lock:
                state_snapshot = self.server.state.control_snapshot()
                removal_events = copy.deepcopy(self.server.state.removal_events)
            self.write_json(
                HTTPStatus.OK,
                {
                    "name": "Transmission Remote Mac mock RPC",
                    "rpcPath": self.server.rpc_path,
                    "sessionHeader": "X-Transmission-Session-Id",
                    "sessionId": self.server.state.session_id,
                    "removalEvents": removal_events,
                    "responseDelayMilliseconds": self.server.response_delay_ms,
                    "rpcVersionSemver": self.server.rpc_version_semver,
                    **state_snapshot,
                },
            )
            return
        if self.path == STATE_CONTROL_PATH:
            if not self.authorized():
                self.write_unauthorized()
                return
            with self.server.state.lock:
                state_snapshot = self.server.state.control_snapshot()
            self.write_json(HTTPStatus.OK, state_snapshot)
            return
        self.write_text(HTTPStatus.NOT_FOUND, f"Mock RPC path is {self.server.rpc_path}\n")

    def do_POST(self) -> None:
        request_path = urllib.parse.urlsplit(self.path).path
        if request_path == DELTA_CONTROL_PATH:
            self.handle_delta_control()
            return
        if request_path != self.server.rpc_path:
            self.write_text(HTTPStatus.NOT_FOUND, f"Mock RPC path is {self.server.rpc_path}\n")
            return

        if not self.authorized():
            self.write_unauthorized()
            return

        if self.server.challenge_sessions:
            supplied = self.headers.get("X-Transmission-Session-Id", "")
            if supplied != self.server.state.session_id:
                self.send_response(HTTPStatus.CONFLICT)
                self.send_header("X-Transmission-Session-Id", self.server.state.session_id)
                if self.server.rpc_version_semver:
                    self.send_header("X-Transmission-Rpc-Version", self.server.rpc_version_semver)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return

        try:
            request, request_byte_count = self.read_json_object_with_size(
                maximum_bytes=MAXIMUM_RPC_REQUEST_BYTES,
            )
        except ValueError as exc:
            self.write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
            return

        is_json_rpc = "jsonrpc" in request
        request_id: Any = request.get("id")
        try:
            if is_json_rpc:
                method, arguments, request_id = json_request_to_legacy(request)
            else:
                method = request.get("method")
                arguments = request.get("arguments") or {}
                if not isinstance(method, str) or not isinstance(arguments, dict):
                    raise ValueError("request must contain method and object arguments")
        except ValueError as exc:
            self.write_rpc_failure(str(exc), json_rpc=is_json_rpc, request_id=request_id)
            return

        self.server.state.begin_request(method, arguments, request_byte_count)
        try:
            try:
                if self.server.response_delay_ms:
                    time.sleep(self.server.response_delay_ms / 1_000)
                with self.server.state.lock:
                    response_arguments = self.dispatch(method, arguments)
            except ValueError as exc:
                self.write_rpc_failure(str(exc), json_rpc=is_json_rpc, request_id=request_id)
                return

            self.write_json(
                HTTPStatus.OK,
                rpc_success_payload(
                    method,
                    response_arguments,
                    json_rpc=is_json_rpc,
                    request_id=request_id,
                ),
            )
        finally:
            self.server.state.end_request()

    def handle_delta_control(self) -> None:
        if not self.authorized():
            self.write_unauthorized()
            return
        try:
            payload = self.read_json_object(maximum_bytes=65_536)
            with self.server.state.lock:
                snapshot = self.server.state.control_delta(payload)
        except ValueError as exc:
            self.write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
            return
        self.write_json(HTTPStatus.OK, snapshot)

    def read_json_object(self, *, maximum_bytes: int) -> dict[str, Any]:
        payload, _ = self.read_json_object_with_size(maximum_bytes=maximum_bytes)
        return payload

    def read_json_object_with_size(
        self,
        *,
        maximum_bytes: int,
    ) -> tuple[dict[str, Any], int]:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise ValueError("Content-Length must be an integer") from exc
        if length <= 0 or length > maximum_bytes:
            raise ValueError(f"request body must contain 1 to {maximum_bytes} bytes")
        try:
            raw = self.rfile.read(length)
        except socket.timeout as exc:
            raise ValueError("request body timed out") from exc
        if len(raw) != length:
            raise ValueError("request body ended before Content-Length bytes were received")
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ValueError(f"malformed JSON: {exc}") from exc
        if not isinstance(payload, dict):
            raise ValueError("request body must be a JSON object")
        return payload, length

    def write_unauthorized(self) -> None:
        body = b"Authentication required\n"
        self.send_response(HTTPStatus.UNAUTHORIZED)
        self.send_header("WWW-Authenticate", 'Basic realm="Transmission Mock"')
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authorized(self) -> bool:
        username = self.server.username
        if not username:
            return True
        expected = base64.b64encode(f"{username}:{self.server.password}".encode("utf-8")).decode("ascii")
        return self.headers.get("Authorization", "") == f"Basic {expected}"

    def dispatch(self, method: str, arguments: dict[str, Any]) -> dict[str, Any] | None:
        if method == "session-get":
            return copy.deepcopy(self.server.state.session)
        if method == "session-set":
            self.server.state.session.update(copy.deepcopy(arguments))
            return None
        if method == "session-stats":
            return self.session_stats()
        if method == "free-space":
            return self.free_space(arguments)
        if method == "port-test":
            return self.server.state.port_test(arguments)
        if method == "blocklist-update":
            return self.server.state.blocklist_update(arguments)
        if method == "torrent-get":
            return self.torrent_get(arguments)
        if method == "torrent-add":
            return self.torrent_add(arguments)
        if method in OBSERVED_MUTATION_METHODS:
            return self.dispatch_observed_mutation(method, arguments)
        if method in SAFE_ACTION_METHODS:
            self.apply_action(method, arguments)
            return None
        raise ValueError(f"method name not recognized: {method}")

    def dispatch_observed_mutation(
        self,
        method: str,
        arguments: dict[str, Any],
    ) -> dict[str, Any] | None:
        operation_id = self.server.state.begin_mutation(method, arguments)
        try:
            injected_failure = self.server.state.take_mutation_failure(method)
            if injected_failure is not None:
                raise ValueError(injected_failure)
            if method == "torrent-rename-path":
                if self.server.state.session.get("rpc-version", 0) < 15:
                    raise ValueError("torrent-rename-path requires RPC version 15 or newer")
                result = self.server.state.rename_torrent_path(
                    arguments,
                    operation_id=operation_id,
                )
            else:
                if (
                    method == "torrent-set-location"
                    and self.server.state.session.get("rpc-version", 0) < 6
                ):
                    raise ValueError("torrent-set-location requires RPC version 6 or newer")
                self.apply_action(method, arguments, operation_id=operation_id)
                result = None
        except ValueError as exc:
            self.server.state.record_mutation_phase(
                operation_id,
                method,
                "failed",
                error=str(exc),
            )
            raise

        phase = "running" if method == "torrent-verify" else "completed"
        self.server.state.record_mutation_phase(operation_id, method, phase)
        return result

    def session_stats(self) -> dict[str, Any]:
        rows = self.server.state.torrents
        download_speed = sum(max(0, int(row.get("rateDownload", 0))) for row in rows)
        upload_speed = sum(max(0, int(row.get("rateUpload", 0))) for row in rows)
        paused = sum(1 for row in rows if row.get("status") == STATUS_STOPPED)
        active = sum(1 for row in rows if row.get("status") != STATUS_STOPPED)
        uploaded = sum(max(0, int(row.get("uploadedEver", 0))) for row in rows)
        downloaded = sum(max(0, int(row.get("downloadedEver", 0))) for row in rows)
        current = {
            "uploadedBytes": uploaded // 10,
            "downloadedBytes": downloaded // 10,
            "filesAdded": len(rows),
            "sessionCount": 1,
            "secondsActive": 3_600,
        }
        cumulative = {
            "uploadedBytes": uploaded,
            "downloadedBytes": downloaded,
            "filesAdded": len(rows) * 3,
            "sessionCount": 17,
            "secondsActive": 172_800,
        }
        return {
            "activeTorrentCount": active,
            "pausedTorrentCount": paused,
            "torrentCount": len(rows),
            "downloadSpeed": download_speed,
            "uploadSpeed": upload_speed,
            "current-stats": current,
            "cumulative-stats": cumulative,
        }

    def free_space(self, arguments: dict[str, Any]) -> dict[str, Any]:
        path = arguments.get("path")
        if not isinstance(path, str) or not path.strip():
            raise ValueError("free-space requires path")

        size_bytes = self.server.state.session.get("download-dir-free-space", 128 * 1024 * 1024 * 1024)
        if not isinstance(size_bytes, int):
            size_bytes = 128 * 1024 * 1024 * 1024
        return {"size-bytes": size_bytes}

    def torrent_get(self, arguments: dict[str, Any]) -> dict[str, Any]:
        requested = arguments.get("fields") or ALL_TORRENT_FIELDS
        if not isinstance(requested, list) or not all(isinstance(item, str) for item in requested):
            raise ValueError("torrent-get fields must be an array of strings")
        ids_value = arguments.get("ids")
        rows = self.selected_torrents(ids_value)
        self.server.state.advance_verifications(rows)
        removed = (
            sorted(self.server.state.recently_removed_ids)
            if self.is_recently_active(ids_value) and self.server.state.delta_controlled
            else []
        )
        if arguments.get("format") == "table":
            return {
                "fields": requested,
                "torrents": [[copy.deepcopy(row.get(field)) for field in requested] for row in rows],
                "removed": removed,
            }
        return {
            "torrents": [
                {field: copy.deepcopy(row[field]) for field in requested if field in row}
                for row in rows
            ],
            "removed": removed,
        }

    def torrent_add(self, arguments: dict[str, Any]) -> dict[str, Any]:
        source = arguments.get("filename") or arguments.get("metainfo")
        if not isinstance(source, str) or not source.strip():
            raise ValueError("torrent-add requires filename or metainfo")

        source_key = hashlib.sha1(source.encode("utf-8")).hexdigest()
        duplicate_id = self.server.state.added_sources.get(source_key)
        if duplicate_id is not None:
            row = self.torrent_by_id(duplicate_id)
            return {"torrent-duplicate": self.add_response(row)}

        torrent_id = self.server.state.next_id
        self.server.state.next_id += 1
        name = self.name_for_added_torrent(source, torrent_id)
        paused = bool(arguments.get("paused", False))
        row = torrent(
            torrent_id,
            name,
            status=STATUS_STOPPED if paused else STATUS_DOWNLOADING,
            percent_done=0.0,
            total_size=536_870_912,
            left_until_done=536_870_912,
            rate_download=0 if paused else 512_000,
            labels=["added"],
            queue=len(self.server.state.torrents),
        )
        if isinstance(arguments.get("download-dir"), str):
            row["downloadDir"] = arguments["download-dir"]
        self.server.state.torrents.append(row)
        self.server.state.added_sources[source_key] = torrent_id
        self.server.state.mark_changed({torrent_id})
        return {"torrent-added": self.add_response(row)}

    def apply_action(
        self,
        method: str,
        arguments: dict[str, Any],
        *,
        operation_id: int | None = None,
    ) -> None:
        if method.startswith("queue-move-"):
            self.apply_queue_action(method, arguments.get("ids"))
            return

        rows = self.selected_torrents(arguments.get("ids"))
        selected_ids = {row["id"] for row in rows}
        if method in {"torrent-start", "torrent-start-now"}:
            for row in rows:
                row["status"] = STATUS_SEEDING if int(row.get("leftUntilDone", 0)) == 0 else STATUS_DOWNLOADING
                if row["status"] == STATUS_DOWNLOADING and int(row.get("rateDownload", 0)) == 0:
                    row["rateDownload"] = 384_000
        elif method == "torrent-stop":
            for row in rows:
                row["status"] = STATUS_STOPPED
                row["rateDownload"] = 0
                row["rateUpload"] = 0
        elif method == "torrent-verify":
            if operation_id is None:
                raise ValueError("torrent-verify requires operation ownership")
            self.server.state.begin_verification(rows, operation_id)
        elif method == "torrent-reannounce":
            for row in rows:
                row["announceResponse"] = "Manual announce accepted by mock"
                row["activityDate"] = BASE_TIME
        elif method == "torrent-remove":
            delete_local_data = arguments.get("delete-local-data")
            if not isinstance(delete_local_data, bool):
                raise ValueError("torrent-remove delete-local-data must be a boolean")
            ids = {row["id"] for row in rows}
            self.server.state.removal_events.append(
                {
                    "ids": sorted(ids),
                    "delete-local-data": delete_local_data,
                }
            )
            self.server.state.torrents = [row for row in self.server.state.torrents if row["id"] not in ids]
            self.resequence_queue()
            self.server.state.mark_removed(ids)
            self.server.state.mark_changed({row["id"] for row in self.server.state.torrents})
            return
        elif method == "torrent-set-location":
            self.apply_set_location(
                rows,
                arguments,
                operation_id=operation_id,
            )
            self.server.state.last_torrent_set_location = {
                "ids": sorted(row["id"] for row in rows),
                "hashes": sorted(row["hashString"] for row in rows),
                "location": arguments["location"],
                "move": arguments["move"],
            }
        elif method == "torrent-set":
            self.apply_torrent_set(rows, arguments)
        self.server.state.mark_changed(selected_ids)

    def apply_set_location(
        self,
        rows: list[dict[str, Any]],
        arguments: dict[str, Any],
        *,
        operation_id: int | None = None,
    ) -> None:
        location = arguments.get("location")
        move = arguments.get("move")
        if not isinstance(location, str) or not location.strip():
            raise ValueError("torrent-set-location requires location")
        if not isinstance(move, bool):
            raise ValueError("torrent-set-location move must be a boolean")
        if operation_id is not None:
            self.server.state.record_mutation_phase(
                operation_id,
                "torrent-set-location",
                "running",
            )
        for row in rows:
            row["downloadDir"] = location

    @staticmethod
    def sync_tracker_rows(row: dict[str, Any], tracker_list: str) -> None:
        row["trackerList"] = tracker_list
        row["trackers"] = tracker_rows(int(row.get("id", 0)), tracker_list)
        row["trackerStats"] = [
            {
                **tracker,
                "host": urllib.parse.urlsplit(tracker["announce"]).hostname or tracker["announce"],
                "announceState": 0,
                "hasAnnounced": True,
                "lastAnnounceSucceeded": True,
                "lastAnnounceResult": "Success",
                "nextAnnounceTime": BASE_TIME + 1_800,
                "seederCount": 12,
                "leecherCount": 4,
                "downloadCount": 30,
            }
            for tracker in row["trackers"]
        ]

    @staticmethod
    def apply_torrent_set(rows: list[dict[str, Any]], arguments: dict[str, Any]) -> None:
        updates = {key: copy.deepcopy(value) for key, value in arguments.items() if key != "ids"}
        for row in rows:
            row_updates = copy.deepcopy(updates)
            trackers = copy.deepcopy(row.get("trackers", []))
            if "trackerAdd" in row_updates:
                tracker_add = row_updates.pop("trackerAdd")
                if not isinstance(tracker_add, list) or not all(isinstance(url, str) and url.strip() for url in tracker_add):
                    raise ValueError("torrent-set trackerAdd must contain announce URLs")
                trackers.extend(
                    {"id": -1, "announce": url.strip(), "scrape": url.strip().replace("/announce", "/scrape")}
                    for url in tracker_add
                )
            if "trackerReplace" in row_updates:
                tracker_replace = row_updates.pop("trackerReplace")
                if not isinstance(tracker_replace, list) or len(tracker_replace) % 2:
                    raise ValueError("torrent-set trackerReplace must contain id and URL pairs")
                replacements = dict(zip(tracker_replace[::2], tracker_replace[1::2]))
                if not all(isinstance(tracker_id, int) for tracker_id in replacements):
                    raise ValueError("torrent-set trackerReplace ids must be integers")
                if not all(isinstance(url, str) and url.strip() for url in replacements.values()):
                    raise ValueError("torrent-set trackerReplace URLs must be non-empty")
                for tracker in trackers:
                    tracker_id = tracker.get("id")
                    if tracker_id in replacements:
                        announce = replacements[tracker_id].strip()
                        tracker["announce"] = announce
                        tracker["scrape"] = announce.replace("/announce", "/scrape")
            if "trackerRemove" in row_updates:
                tracker_remove = row_updates.pop("trackerRemove")
                if not isinstance(tracker_remove, list) or not all(isinstance(tracker_id, int) for tracker_id in tracker_remove):
                    raise ValueError("torrent-set trackerRemove must contain tracker ids")
                removed_ids = set(tracker_remove)
                trackers = [tracker for tracker in trackers if tracker.get("id") not in removed_ids]
            if any(key in arguments for key in ("trackerAdd", "trackerReplace", "trackerRemove")):
                tracker_list = "\n".join(str(tracker.get("announce", "")).strip() for tracker in trackers if tracker.get("announce"))
                MockState.sync_tracker_rows(row, tracker_list)

            for key, value in row_updates.items():
                if key == "peer-limit":
                    row["maxConnectedPeers"] = value
                elif key == "trackerList":
                    MockState.sync_tracker_rows(row, value)
                else:
                    row[key] = value
                if key == "downloadLimited":
                    row["downloadLimitMode"] = 1 if value else 0
                elif key == "uploadLimited":
                    row["uploadLimitMode"] = 1 if value else 0

    def apply_queue_action(self, method: str, ids_value: Any) -> None:
        selected_ids = [row["id"] for row in self.selected_torrents(ids_value)]
        if not selected_ids:
            return
        rows = self.server.state.sorted_torrents()
        selected = [row for row in rows if row["id"] in selected_ids]
        remaining = [row for row in rows if row["id"] not in selected_ids]
        if method == "queue-move-top":
            rows = selected + remaining
        elif method == "queue-move-bottom":
            rows = remaining + selected
        elif method == "queue-move-up":
            rows = self.move_one(rows, selected_ids, -1)
        elif method == "queue-move-down":
            rows = self.move_one(rows, selected_ids, 1)
        self.server.state.torrents = rows
        self.resequence_queue()
        self.server.state.mark_changed({row["id"] for row in rows})

    @staticmethod
    def move_one(rows: list[dict[str, Any]], selected_ids: list[int], direction: int) -> list[dict[str, Any]]:
        indices = range(len(rows)) if direction < 0 else range(len(rows) - 1, -1, -1)
        selected = set(selected_ids)
        for index in indices:
            swap = index + direction
            if rows[index]["id"] in selected and 0 <= swap < len(rows) and rows[swap]["id"] not in selected:
                rows[index], rows[swap] = rows[swap], rows[index]
        return rows

    def selected_torrents(self, ids_value: Any) -> list[dict[str, Any]]:
        rows = self.server.state.sorted_torrents()
        if ids_value is None:
            return rows
        if self.is_recently_active(ids_value):
            if self.server.state.delta_controlled:
                active_ids = self.server.state.recently_active_ids
                return [row for row in rows if row.get("id") in active_ids]
            return rows
        if isinstance(ids_value, (int, str)):
            selected = {ids_value}
        elif isinstance(ids_value, list):
            selected = {item for item in ids_value if isinstance(item, (int, str))}
        else:
            raise ValueError(
                "ids must be absent, an id/hash, an id/hash array, recently-active, or recently_active"
            )
        return [
            row for row in rows
            if row.get("id") in selected or row.get("hashString") in selected
        ]

    @staticmethod
    def is_recently_active(ids_value: Any) -> bool:
        return isinstance(ids_value, str) and ids_value in {"recently-active", "recently_active"}

    def torrent_by_id(self, torrent_id: int) -> dict[str, Any]:
        for row in self.server.state.torrents:
            if row.get("id") == torrent_id:
                return row
        raise ValueError(f"invalid torrent id: {torrent_id}")

    def resequence_queue(self) -> None:
        for index, row in enumerate(self.server.state.sorted_torrents()):
            row["queuePosition"] = index

    @staticmethod
    def name_for_added_torrent(source: str, torrent_id: int) -> str:
        if source.startswith("magnet:"):
            params = urllib.parse.parse_qs(urllib.parse.urlsplit(source).query)
            if params.get("dn"):
                return urllib.parse.unquote(params["dn"][0])
            return f"Mock magnet {torrent_id}"
        if len(source) > 80 and "/" not in source:
            return f"Mock metainfo {torrent_id}"
        base = posixpath.basename(source) or os.path.basename(source)
        return base or f"Mock torrent {torrent_id}"

    @staticmethod
    def add_response(row: dict[str, Any]) -> dict[str, Any]:
        return {"id": row["id"], "name": row["name"], "hashString": row["hashString"]}

    def write_rpc_failure(self, message: str, *, json_rpc: bool = False, request_id: Any = None) -> None:
        self.write_json(
            HTTPStatus.OK,
            rpc_failure_payload(
                message,
                json_rpc=json_rpc,
                request_id=request_id,
            ),
        )

    def write_json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def write_text(self, status: HTTPStatus, text: str) -> None:
        body = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class MockTransmissionServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    client_io_timeout_seconds = 5.0

    def __init__(
        self,
        address: tuple[str, int],
        handler: type[MockTransmissionHandler],
        *,
        rpc_path: str,
        state: MockState,
        challenge_sessions: bool,
        username: str,
        password: str,
        rpc_version_semver: str | None,
        response_delay_ms: int,
        verbose: bool,
    ) -> None:
        super().__init__(address, handler)
        self.rpc_path = rpc_path
        self.state = state
        self.challenge_sessions = challenge_sessions
        self.username = username
        self.password = password
        self.rpc_version_semver = rpc_version_semver
        self.response_delay_ms = response_delay_ms
        self.verbose = verbose


def load_fixture(path: str | None) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    session = default_session()
    torrents = default_torrents()
    if path is None:
        return session, torrents
    with open(path, "r", encoding="utf-8") as fh:
        payload = json.load(fh)
    if isinstance(payload, list):
        torrents = payload
    elif isinstance(payload, dict):
        if isinstance(payload.get("session"), dict):
            session.update(payload["session"])
        if isinstance(payload.get("torrents"), list):
            torrents = payload["torrents"]
    else:
        raise SystemExit("fixture must be a JSON object or torrent array")
    return session, torrents


def parse_id_list(value: str | None, option: str) -> list[int] | None:
    if value is None:
        return None
    if not value.strip():
        return []
    result: list[int] = []
    for item in value.split(","):
        try:
            torrent_id = int(item.strip())
        except ValueError as exc:
            raise SystemExit(f"{option} must be a comma-separated list of positive integer ids") from exc
        if torrent_id <= 0:
            raise SystemExit(f"{option} must be a comma-separated list of positive integer ids")
        result.append(torrent_id)
    return sorted(set(result))


def parse_mutation_failures(values: list[str] | None) -> dict[str, list[str]]:
    result: dict[str, list[str]] = {}
    for value in values or []:
        method, separator, message = value.partition("=")
        if separator != "=" or method not in OBSERVED_MUTATION_METHODS or not message.strip():
            methods = ", ".join(sorted(OBSERVED_MUTATION_METHODS))
            raise SystemExit(
                "--fail-next-mutation must be METHOD=MESSAGE, where METHOD is one of "
                f"{methods}"
            )
        result.setdefault(method, []).append(message)
    return result


def install_large_detail_torrent(
    torrents: list[dict[str, Any]],
    *,
    generated_count: int | None,
) -> list[dict[str, Any]]:
    rows = list(torrents)
    if generated_count is not None and rows:
        rows[0] = large_detail_torrent(torrent_id=1, queue=0)
        return rows
    torrent_id = max((int(row.get("id", 0)) for row in rows), default=0) + 1
    rows.append(large_detail_torrent(torrent_id=torrent_id, queue=len(rows)))
    return rows


def json_request_to_legacy(request: dict[str, Any]) -> tuple[str, dict[str, Any], Any]:
    if request.get("jsonrpc") != "2.0":
        raise ValueError("JSON-RPC request must declare jsonrpc 2.0")
    if "id" not in request or isinstance(request["id"], (dict, list, bool)):
        raise ValueError("JSON-RPC request must contain a scalar id")
    method = request.get("method")
    if not isinstance(method, str) or method not in JSON_RPC_METHODS:
        raise ValueError(f"method name not recognized: {method}")
    params = request.get("params", {})
    if not isinstance(params, dict):
        raise ValueError("JSON-RPC params must be an object")

    arguments: dict[str, Any] = {}
    for wire_key, value in params.items():
        if wire_key == "preferred_transports":
            if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
                raise ValueError("preferred_transports must be an array of strings")
            arguments["utp-enabled"] = "utp" in value
            continue
        canonical_key = JSON_ARGUMENT_NAMES.get(wire_key, wire_key)
        if canonical_key == "fields":
            if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
                raise ValueError("torrent_get fields must be an array of strings")
            value = [JSON_TORRENT_FIELD_NAMES.get(item, item) for item in value]
        elif canonical_key == "ids" and value == "recently_active":
            value = "recently-active"
        elif canonical_key == "encryption" and value == "allowed":
            value = "tolerated"
        arguments[canonical_key] = value
    return JSON_RPC_METHODS[method], arguments, request["id"]


def json_result(method: str, result: dict[str, Any] | None) -> dict[str, Any]:
    result = copy.deepcopy(result or {})
    if method == "session-get":
        payload = rename_object_keys(result, SESSION_RESULT_NAMES)
        if "utp-enabled" in result:
            payload.pop("utp_enabled", None)
            payload["preferred_transports"] = ["utp", "tcp"] if result["utp-enabled"] else ["tcp"]
        if payload.get("encryption") == "tolerated":
            payload["encryption"] = "allowed"
        return payload
    if method == "session-stats":
        return rename_object_keys(result, STATS_RESULT_NAMES, recursive=True)
    if method == "free-space":
        return rename_object_keys(result, {"size-bytes": "size_bytes", "total-size": "total_size"})
    if method == "port-test":
        return rename_object_keys(result, {"port-is-open": "port_is_open", "ip-protocol": "ip_protocol"})
    if method == "blocklist-update":
        return rename_object_keys(result, {"blocklist-size": "blocklist_size"})
    if method == "torrent-add":
        payload: dict[str, Any] = {}
        for key, value in result.items():
            wire_key = {"torrent-added": "torrent_added", "torrent-duplicate": "torrent_duplicate"}.get(key, key)
            payload[wire_key] = rename_object_keys(value, TORRENT_FIELD_NAMES, recursive=True)
        return payload
    if method == "torrent-get":
        payload = copy.deepcopy(result)
        if isinstance(payload.get("fields"), list):
            payload["fields"] = [TORRENT_FIELD_NAMES.get(field, field) for field in payload["fields"]]
        torrents = payload.get("torrents")
        if isinstance(torrents, list):
            if torrents and isinstance(torrents[0], list):
                if torrents[0] and all(isinstance(item, str) for item in torrents[0]):
                    torrents[0] = [TORRENT_FIELD_NAMES.get(field, field) for field in torrents[0]]
            else:
                payload["torrents"] = [
                    rename_object_keys(row, TORRENT_FIELD_NAMES, recursive=True)
                    if isinstance(row, dict) else row
                    for row in torrents
                ]
        return payload
    return result


def rpc_success_payload(
    method: str,
    result: dict[str, Any] | None,
    *,
    json_rpc: bool,
    request_id: Any = None,
) -> dict[str, Any]:
    if json_rpc:
        return {
            "jsonrpc": "2.0",
            "result": json_result(method, result),
            "id": request_id,
        }
    if result is None:
        return {"result": "success"}
    return {"result": "success", "arguments": copy.deepcopy(result)}


def rpc_failure_payload(
    message: str,
    *,
    json_rpc: bool,
    request_id: Any = None,
) -> dict[str, Any]:
    if json_rpc:
        return {
            "jsonrpc": "2.0",
            "error": {"code": -32602, "message": message},
            "id": request_id,
        }
    return {"result": message, "arguments": {}}


def rename_object_keys(
    value: Any,
    names: dict[str, str],
    *,
    recursive: bool = False,
) -> Any:
    if isinstance(value, list):
        return [rename_object_keys(item, names, recursive=recursive) for item in value]
    if not isinstance(value, dict):
        return value
    return {
        names.get(key, key): rename_object_keys(item, names, recursive=True) if recursive else copy.deepcopy(item)
        for key, item in value.items()
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a deterministic local mock Transmission RPC server.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--host", default="127.0.0.1", help="interface to bind")
    parser.add_argument("--port", type=int, default=9091, help="port to bind")
    parser.add_argument("--rpc-path", default="/transmission/rpc", help="RPC endpoint path")
    parser.add_argument("--session-id", default=DEFAULT_SESSION_ID, help="session id returned on 409")
    parser.add_argument("--no-session-challenge", action="store_true", help="accept requests without 409 challenge")
    parser.add_argument("--rpc-version", type=int, default=None, help="override session-get rpc-version")
    parser.add_argument(
        "--rpc-version-semver",
        default=None,
        help="advertise this version on the 409 challenge, for example 6.0.0 to negotiate JSON-RPC 2.0",
    )
    parser.add_argument("--username", default="", help="require HTTP Basic auth username")
    parser.add_argument("--password", default="", help="require HTTP Basic auth password")
    parser.add_argument("--fixture", default=None, help="JSON fixture with optional session and torrents keys")
    parser.add_argument(
        "--torrent-count",
        type=int,
        choices=GENERATED_TORRENT_COUNTS,
        default=None,
        help="replace the default fixture with a generated scale fixture",
    )
    parser.add_argument(
        "--large-detail-torrent",
        action="store_true",
        help=f"include one deterministic torrent with {LARGE_DETAIL_FILE_COUNT} files",
    )
    parser.add_argument(
        "--recently-active-ids",
        default=None,
        help="comma-separated ids returned by recently-active/recently_active queries",
    )
    parser.add_argument(
        "--recently-removed-ids",
        default=None,
        help="comma-separated removed ids returned by recently-active/recently_active queries",
    )
    parser.add_argument(
        "--response-delay-ms",
        type=int,
        default=0,
        help="delay each accepted RPC response for slow-RPC and overlap validation",
    )
    parser.add_argument(
        "--port-closed",
        action="store_true",
        help="return a deterministic closed result from port-test instead of open",
    )
    parser.add_argument(
        "--blocklist-size",
        type=int,
        default=65_536,
        help="non-negative entry count returned by blocklist-update",
    )
    parser.add_argument(
        "--fail-next-mutation",
        action="append",
        default=None,
        metavar="METHOD=MESSAGE",
        help="fail the next named verify, set-location, or rename RPC with the supplied message",
    )
    parser.add_argument("--verbose", action="store_true", help="log HTTP requests")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.fixture is not None and args.torrent_count is not None:
        raise SystemExit("--fixture and --torrent-count cannot be used together")
    if args.response_delay_ms < 0:
        raise SystemExit("--response-delay-ms must be zero or greater")
    if args.blocklist_size < 0:
        raise SystemExit("--blocklist-size must be zero or greater")
    if args.rpc_version_semver is not None:
        parts = args.rpc_version_semver.split(".")
        if len(parts) != 3 or not all(part.isdigit() for part in parts):
            raise SystemExit("--rpc-version-semver must contain three non-negative integers")
    session, torrents = load_fixture(args.fixture)
    if args.torrent_count is not None:
        torrents = generated_torrents(args.torrent_count)
    if args.large_detail_torrent:
        torrents = install_large_detail_torrent(torrents, generated_count=args.torrent_count)
    if args.rpc_version is not None:
        session["rpc-version"] = args.rpc_version
    if args.rpc_version_semver is not None:
        session["rpc-version-semver"] = args.rpc_version_semver

    recently_active_ids = parse_id_list(args.recently_active_ids, "--recently-active-ids")
    recently_removed_ids = parse_id_list(args.recently_removed_ids, "--recently-removed-ids")
    mutation_failures = parse_mutation_failures(args.fail_next_mutation)
    try:
        state = MockState(
            session=session,
            torrents=torrents,
            session_id=args.session_id,
            recently_active_ids=recently_active_ids,
            recently_removed_ids=recently_removed_ids,
            port_is_open=not args.port_closed,
            blocklist_size=args.blocklist_size,
            mutation_failures=mutation_failures,
        )
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc
    server = MockTransmissionServer(
        (args.host, args.port),
        MockTransmissionHandler,
        rpc_path=args.rpc_path,
        state=state,
        challenge_sessions=not args.no_session_challenge,
        username=args.username,
        password=args.password,
        rpc_version_semver=args.rpc_version_semver,
        response_delay_ms=args.response_delay_ms,
        verbose=args.verbose,
    )
    endpoint = f"http://{args.host}:{args.port}{args.rpc_path}"
    print(f"Mock Transmission RPC listening on {endpoint}", flush=True)
    print(f"Session challenge: {'on' if server.challenge_sessions else 'off'}; session id: {args.session_id}", flush=True)
    if args.rpc_version_semver:
        print(f"RPC negotiation header: {args.rpc_version_semver}", flush=True)
    if args.username:
        print(f"Basic auth: username={args.username!r}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nMock Transmission RPC stopped", flush=True)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
