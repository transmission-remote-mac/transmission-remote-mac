#!/usr/bin/env python3
# Transmission Remote Mac
# SPDX-FileCopyrightText: 2026 aidpok
# SPDX-License-Identifier: GPL-2.0-only
# See CREDITS.md for upstream attribution.

import base64
import http.client
import json
import socket
import sys
import threading
import unittest
import urllib.request
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mock_transmission_rpc as mock


class ScaleAndTransportFixtureTests(unittest.TestCase):
    @contextmanager
    def server(
        self,
        *,
        torrents: list[dict],
        recently_active_ids: list[int] | None = None,
        recently_removed_ids: list[int] | None = None,
        rpc_version_semver: str | None = None,
        rpc_version: int = 18,
        username: str = "",
        password: str = "",
        mutation_failures: dict[str, list[str]] | None = None,
        handler_class: type[mock.MockTransmissionHandler] = mock.MockTransmissionHandler,
    ) -> Iterator[mock.MockTransmissionServer]:
        session = mock.default_session()
        session["rpc-version"] = rpc_version
        state = mock.MockState(
            session=session,
            torrents=torrents,
            session_id="fixture-test-session",
            recently_active_ids=recently_active_ids,
            recently_removed_ids=recently_removed_ids,
            mutation_failures=mutation_failures,
        )
        server = mock.MockTransmissionServer(
            ("127.0.0.1", 0),
            handler_class,
            rpc_path="/transmission/rpc",
            state=state,
            challenge_sessions=False,
            username=username,
            password=password,
            rpc_version_semver=rpc_version_semver,
            response_delay_ms=0,
            verbose=False,
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def post(self, server: mock.MockTransmissionServer, payload: dict) -> dict:
        return self.post_path(server, "/transmission/rpc", payload)

    def post_path(
        self,
        server: mock.MockTransmissionServer,
        path: str,
        payload: dict,
    ) -> dict:
        host, port = server.server_address
        request = urllib.request.Request(
            f"http://{host}:{port}{path}",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            self.assertEqual(response.status, 200)
            return json.load(response)

    def test_delta_control_can_stop_every_torrent_and_publish_each_changed_row(self) -> None:
        torrents = mock.generated_torrents(1_000)
        with self.server(
            torrents=torrents,
            recently_active_ids=[],
        ) as server:
            snapshot = self.post_path(server, mock.DELTA_CONTROL_PATH, {
                "mode": "replace",
                "allTorrentsState": "stopped",
            })
            delta = self.post(server, {
                "method": "torrent-get",
                "arguments": {
                    "ids": "recently-active",
                    "fields": [
                        "id",
                        "status",
                        "rateDownload",
                        "rateUpload",
                        "recheckProgress",
                        "eta",
                    ],
                },
            })["arguments"]

        self.assertEqual(snapshot["recentlyActiveIds"], list(range(1, 1_001)))
        self.assertEqual(snapshot["stoppedTorrentCount"], 1_000)
        self.assertTrue(snapshot["allTorrentsStopped"])
        self.assertEqual(snapshot["torrentDownloadRate"], 0)
        self.assertEqual(snapshot["torrentUploadRate"], 0)
        self.assertEqual(snapshot["activeVerificationCount"], 0)
        self.assertEqual(len(delta["torrents"]), 1_000)
        self.assertEqual(delta["removed"], [])
        self.assertTrue(all(
            row["status"] == mock.STATUS_STOPPED
            for row in delta["torrents"]
        ))
        self.assertTrue(all(row["rateDownload"] == 0 for row in delta["torrents"]))
        self.assertTrue(all(row["rateUpload"] == 0 for row in delta["torrents"]))
        self.assertTrue(all(row["recheckProgress"] == 0 for row in delta["torrents"]))
        self.assertTrue(all(row["eta"] == -1 for row in delta["torrents"]))

    def test_delta_control_rejects_unsupported_all_torrent_state(self) -> None:
        state = mock.MockState(
            session=mock.default_session(),
            torrents=mock.generated_torrents(1),
            session_id="state-test-session",
            recently_active_ids=[],
        )

        with self.assertRaisesRegex(ValueError, "allTorrentsState must be stopped"):
            state.control_delta({"allTorrentsState": "seeding"})

    def test_scale_fixtures_return_exact_requested_row_counts_over_http(self) -> None:
        for count in mock.GENERATED_TORRENT_COUNTS:
            with self.subTest(count=count):
                with self.server(torrents=mock.generated_torrents(count)) as server:
                    response = self.post(server, {
                        "method": "torrent-get",
                        "arguments": {"fields": ["id", "name"]},
                    })
                    self.assertEqual(len(response["arguments"]["torrents"]), count)

    def test_large_detail_fixture_returns_ten_thousand_files_over_http(self) -> None:
        torrents = mock.install_large_detail_torrent(
            mock.generated_torrents(100),
            generated_count=100,
        )
        with self.server(torrents=torrents) as server:
            response = self.post(server, {
                "method": "torrent-get",
                "arguments": {
                    "ids": [1],
                    "fields": ["id", "files", "fileStats"],
                },
            })

        rows = response["arguments"]["torrents"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(len(rows[0]["files"]), mock.LARGE_DETAIL_FILE_COUNT)
        self.assertEqual(len(rows[0]["fileStats"]), mock.LARGE_DETAIL_FILE_COUNT)

    def test_in_flight_accounting_includes_complete_large_response_body_write(self) -> None:
        response_body_started = threading.Event()
        allow_response_body_to_finish = threading.Event()
        first_response_lock = threading.Lock()
        first_response_claimed = [False]
        blocked_body_sizes: list[int] = []

        class BlockingLargeBodyHandler(mock.MockTransmissionHandler):
            def write_json(self, status, payload) -> None:
                with first_response_lock:
                    should_block = (
                        not first_response_claimed[0]
                        and self.path == self.server.rpc_path
                    )
                    if should_block:
                        first_response_claimed[0] = True
                if not should_block:
                    super().write_json(status, payload)
                    return

                body = json.dumps(
                    payload,
                    sort_keys=True,
                    separators=(",", ":"),
                ).encode("utf-8")
                blocked_body_sizes.append(len(body))
                midpoint = len(body) // 2
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body[:midpoint])
                self.wfile.flush()
                response_body_started.set()
                if not allow_response_body_to_finish.wait(timeout=5):
                    raise TimeoutError("test did not release the blocked response body")
                self.wfile.write(body[midpoint:])

        torrents = mock.install_large_detail_torrent(
            mock.generated_torrents(100),
            generated_count=100,
        )
        responses: dict[str, dict] = {}
        failures: list[BaseException] = []

        def send(label: str, payload: dict) -> None:
            try:
                responses[label] = self.post(server, payload)
            except BaseException as error:
                failures.append(error)

        with self.server(
            torrents=torrents,
            handler_class=BlockingLargeBodyHandler,
        ) as server:
            first = threading.Thread(
                target=send,
                args=(
                    "large",
                    {
                        "method": "torrent-get",
                        "arguments": {
                            "ids": [1],
                            "fields": ["id", "files", "fileStats"],
                        },
                    },
                ),
            )
            second = threading.Thread(
                target=send,
                args=("stats", {"method": "session-stats", "arguments": {}}),
            )
            first.start()
            try:
                self.assertTrue(
                    response_body_started.wait(timeout=5),
                    "large response body did not reach the deterministic block",
                )
                with server.state.lock:
                    while_body_blocked = server.state.control_snapshot()
                self.assertEqual(while_body_blocked["inFlightRequests"], 1)

                second.start()
                second.join(timeout=5)
                self.assertFalse(second.is_alive(), "second RPC did not finish")
                with server.state.lock:
                    while_second_finished = server.state.control_snapshot()
                self.assertEqual(while_second_finished["inFlightRequests"], 1)
                self.assertEqual(while_second_finished["maxInFlightRequests"], 2)
            finally:
                allow_response_body_to_finish.set()
                first.join(timeout=5)
                second.join(timeout=5)

            self.assertFalse(first.is_alive(), "large RPC did not finish")
            self.assertFalse(second.is_alive(), "second RPC did not finish after cleanup")
            with server.state.lock:
                after_responses = server.state.control_snapshot()

        self.assertFalse(failures, failures)
        self.assertGreater(blocked_body_sizes[0], 1_000_000)
        self.assertEqual(after_responses["inFlightRequests"], 0)
        self.assertEqual(after_responses["maxInFlightRequests"], 2)
        self.assertEqual(len(responses["large"]["arguments"]["torrents"][0]["files"]), 10_000)
        self.assertEqual(responses["stats"]["result"], "success")

    def test_delta_fixture_matches_legacy_and_json_rpc_envelopes_over_http(self) -> None:
        for json_rpc in (False, True):
            with self.subTest(json_rpc=json_rpc):
                with self.server(
                    torrents=mock.generated_torrents(100),
                    recently_active_ids=[2],
                    recently_removed_ids=[3],
                    rpc_version_semver="6.0.0" if json_rpc else None,
                ) as server:
                    if json_rpc:
                        response = self.post(server, {
                            "jsonrpc": "2.0",
                            "method": "torrent_get",
                            "params": {
                                "ids": "recently_active",
                                "fields": ["id", "name"],
                            },
                            "id": "delta",
                        })
                        result = response["result"]
                    else:
                        response = self.post(server, {
                            "method": "torrent-get",
                            "arguments": {
                                "ids": "recently-active",
                                "fields": ["id", "name"],
                            },
                        })
                        result = response["arguments"]

                self.assertEqual([row["id"] for row in result["torrents"]], [2])
                self.assertEqual(result["removed"], [3])

    def test_corrupt_ever_field_uses_exact_name_in_both_envelopes(self) -> None:
        torrents = mock.generated_torrents(1)
        expected_value = torrents[0]["corruptEver"]

        for json_rpc in (False, True):
            with self.subTest(json_rpc=json_rpc):
                with self.server(
                    torrents=torrents,
                    rpc_version_semver="6.0.0" if json_rpc else None,
                ) as server:
                    if json_rpc:
                        response = self.post(server, {
                            "jsonrpc": "2.0",
                            "method": "torrent_get",
                            "params": {
                                "ids": [1],
                                "fields": ["id", "corrupt_ever"],
                            },
                            "id": "wasted",
                        })
                        self.assertEqual(
                            response["result"]["torrents"],
                            [{"id": 1, "corrupt_ever": expected_value}],
                        )
                    else:
                        response = self.post(server, {
                            "method": "torrent-get",
                            "arguments": {
                                "ids": [1],
                                "fields": ["id", "corruptEver"],
                            },
                            "tag": 11,
                        })
                        self.assertEqual(
                            response["arguments"]["torrents"],
                            [{"id": 1, "corruptEver": expected_value}],
                        )

    def test_rpc_rejects_invalid_and_oversized_content_lengths(self) -> None:
        with self.server(torrents=[]) as server:
            host, port = server.server_address
            for content_length in ("invalid", str(mock.MAXIMUM_RPC_REQUEST_BYTES + 1)):
                with self.subTest(content_length=content_length):
                    connection = http.client.HTTPConnection(host, port, timeout=5)
                    connection.putrequest("POST", "/transmission/rpc")
                    connection.putheader("Content-Type", "application/json")
                    connection.putheader("Content-Length", content_length)
                    connection.endheaders()
                    response = connection.getresponse()
                    payload = json.loads(response.read().decode("utf-8"))
                    connection.close()

                    self.assertEqual(response.status, 400)
                    self.assertIn("error", payload)

    def test_rpc_rejects_a_body_shorter_than_content_length(self) -> None:
        with self.server(torrents=[]) as server:
            host, port = server.server_address
            with socket.create_connection((host, port), timeout=5) as connection:
                connection.sendall(
                    b"POST /transmission/rpc HTTP/1.0\r\n"
                    b"Content-Type: application/json\r\n"
                    b"Content-Length: 20\r\n"
                    b"\r\n"
                    b"{}"
                )
                connection.shutdown(socket.SHUT_WR)
                response = bytearray()
                while chunk := connection.recv(4_096):
                    response.extend(chunk)

        self.assertIn(b" 400 ", response)
        self.assertIn(b"request body ended before Content-Length", response)

    def test_health_requires_configured_basic_authentication(self) -> None:
        with self.server(
            torrents=[],
            username="fixture-user",
            password="fixture-password",
        ) as server:
            host, port = server.server_address
            connection = http.client.HTTPConnection(host, port, timeout=5)
            connection.request("GET", "/health")
            response = connection.getresponse()
            response.read()
            self.assertEqual(response.status, 401)
            connection.close()

            credentials = base64.b64encode(b"fixture-user:fixture-password").decode("ascii")
            connection = http.client.HTTPConnection(host, port, timeout=5)
            connection.request("GET", "/health", headers={"Authorization": f"Basic {credentials}"})
            response = connection.getresponse()
            payload = json.loads(response.read().decode("utf-8"))
            connection.close()

        self.assertEqual(response.status, 200)
        self.assertEqual(payload["name"], "Transmission Remote Mac mock RPC")

    def test_verify_has_deterministic_running_and_completed_snapshots_in_both_envelopes(self) -> None:
        for json_rpc in (False, True):
            with self.subTest(json_rpc=json_rpc):
                torrents = mock.default_torrents()
                torrent_hash = torrents[0]["hashString"]
                with self.server(
                    torrents=torrents,
                    rpc_version_semver="6.0.0" if json_rpc else None,
                ) as server:
                    verify_payload = (
                        {
                            "jsonrpc": "2.0",
                            "method": "torrent_verify",
                            "params": {"ids": [torrent_hash]},
                            "id": "verify",
                        }
                        if json_rpc
                        else {
                            "method": "torrent-verify",
                            "arguments": {"ids": [torrent_hash]},
                        }
                    )
                    verify_response = self.post(server, verify_payload)
                    self.assertEqual(
                        verify_response,
                        {
                            "jsonrpc": "2.0",
                            "result": {},
                            "id": "verify",
                        } if json_rpc else {"result": "success"},
                    )

                    def torrent_get() -> dict:
                        payload = (
                            {
                                "jsonrpc": "2.0",
                                "method": "torrent_get",
                                "params": {
                                    "ids": [torrent_hash],
                                    "fields": ["id", "status", "recheck_progress"],
                                },
                                "id": "get",
                            }
                            if json_rpc
                            else {
                                "method": "torrent-get",
                                "arguments": {
                                    "ids": [torrent_hash],
                                    "fields": ["id", "status", "recheckProgress"],
                                },
                            }
                        )
                        response = self.post(server, payload)
                        return (
                            response["result"]["torrents"][0]
                            if json_rpc
                            else response["arguments"]["torrents"][0]
                        )

                    running = torrent_get()
                    completed = torrent_get()

                progress_key = "recheck_progress" if json_rpc else "recheckProgress"
                self.assertEqual(running["status"], mock.STATUS_CHECKING)
                self.assertEqual(running[progress_key], 0.56)
                self.assertEqual(completed["status"], mock.STATUS_DOWNLOADING)
                self.assertEqual(completed[progress_key], 1.0)
                self.assertEqual(
                    [event["phase"] for event in server.state.mutation_events],
                    ["submitted", "running", "completed"],
                )
                self.assertEqual(server.state.mutation_events[0]["ids"], [torrent_hash])

    def test_unrelated_detail_reads_do_not_advance_verification_in_both_envelopes(self) -> None:
        for json_rpc in (False, True):
            with self.subTest(json_rpc=json_rpc):
                torrents = mock.default_torrents()
                target = torrents[0]
                unrelated = torrents[1]
                target_hash = target["hashString"]
                unrelated_hash = unrelated["hashString"]
                with self.server(
                    torrents=torrents,
                    rpc_version_semver="6.0.0" if json_rpc else None,
                ) as server:
                    verify_payload = (
                        {
                            "jsonrpc": "2.0",
                            "method": "torrent_verify",
                            "params": {"ids": [target_hash]},
                            "id": "verify",
                        }
                        if json_rpc
                        else {
                            "method": "torrent-verify",
                            "arguments": {"ids": [target_hash]},
                        }
                    )
                    self.post(server, verify_payload)

                    detail_payload = (
                        {
                            "jsonrpc": "2.0",
                            "method": "torrent_get",
                            "params": {
                                "ids": [unrelated_hash],
                                "fields": ["id", "files", "file_stats"],
                            },
                            "id": "detail",
                        }
                        if json_rpc
                        else {
                            "method": "torrent-get",
                            "arguments": {
                                "ids": [unrelated_hash],
                                "fields": ["id", "files", "fileStats"],
                            },
                        }
                    )
                    self.post(server, detail_payload)
                    self.post(server, detail_payload)

                    self.assertEqual(target["status"], mock.STATUS_CHECKING)
                    self.assertEqual(target["recheckProgress"], 0.12)
                    self.assertEqual(
                        [event["phase"] for event in server.state.mutation_events],
                        ["submitted", "running"],
                    )

                    target_payload = (
                        {
                            "jsonrpc": "2.0",
                            "method": "torrent_get",
                            "params": {
                                "ids": [target_hash],
                                "fields": ["id", "status", "recheck_progress"],
                            },
                            "id": "target",
                        }
                        if json_rpc
                        else {
                            "method": "torrent-get",
                            "arguments": {
                                "ids": [target_hash],
                                "fields": ["id", "status", "recheckProgress"],
                            },
                        }
                    )
                    target_response = self.post(server, target_payload)
                    target_row = (
                        target_response["result"]["torrents"][0]
                        if json_rpc
                        else target_response["arguments"]["torrents"][0]
                    )

                progress_key = "recheck_progress" if json_rpc else "recheckProgress"
                self.assertEqual(target_row["status"], mock.STATUS_CHECKING)
                self.assertEqual(target_row[progress_key], 0.56)
                self.assertEqual(
                    [event["phase"] for event in server.state.mutation_events],
                    ["submitted", "running"],
                )

    def test_set_location_records_move_intent_and_targets_for_both_envelopes(self) -> None:
        cases = (
            (False, False),
            (False, True),
            (True, False),
            (True, True),
        )
        for json_rpc, move in cases:
            with self.subTest(json_rpc=json_rpc, move=move):
                torrents = mock.default_torrents()
                torrent_hash = torrents[1]["hashString"]
                with self.server(
                    torrents=torrents,
                    rpc_version_semver="6.0.0" if json_rpc else None,
                ) as server:
                    payload = (
                        {
                            "jsonrpc": "2.0",
                            "method": "torrent_set_location",
                            "params": {
                                "ids": [torrent_hash],
                                "location": "/srv/complete",
                                "move": move,
                            },
                            "id": "location",
                        }
                        if json_rpc
                        else {
                            "method": "torrent-set-location",
                            "arguments": {
                                "ids": [torrent_hash],
                                "location": "/srv/complete",
                                "move": move,
                            },
                        }
                    )
                    response = self.post(server, payload)

                self.assertEqual(
                    response,
                    {
                        "jsonrpc": "2.0",
                        "result": {},
                        "id": "location",
                    } if json_rpc else {"result": "success"},
                )
                self.assertEqual(torrents[1]["downloadDir"], "/srv/complete")
                self.assertEqual(
                    server.state.last_torrent_set_location,
                    {
                        "ids": [2],
                        "hashes": [torrent_hash],
                        "location": "/srv/complete",
                        "move": move,
                    },
                )
                self.assertEqual(
                    [event["phase"] for event in server.state.mutation_events],
                    ["submitted", "running", "completed"],
                )
                self.assertEqual(server.state.mutation_events[0]["move"], move)

    def test_set_location_rejects_rpc_five_without_mutation_in_both_envelopes(self) -> None:
        for json_rpc in (False, True):
            with self.subTest(json_rpc=json_rpc):
                torrents = mock.default_torrents()
                torrent_hash = torrents[0]["hashString"]
                original_location = torrents[0]["downloadDir"]
                with self.server(
                    torrents=torrents,
                    rpc_version=5,
                    rpc_version_semver="6.0.0" if json_rpc else None,
                ) as server:
                    arguments = {
                        "ids": [torrent_hash],
                        "location": "/srv/unsupported",
                        "move": True,
                    }
                    payload = (
                        {
                            "jsonrpc": "2.0",
                            "method": "torrent_set_location",
                            "params": arguments,
                            "id": "unsupported-location",
                        }
                        if json_rpc
                        else {
                            "method": "torrent-set-location",
                            "arguments": arguments,
                        }
                    )
                    response = self.post(server, payload)

                message = "torrent-set-location requires RPC version 6 or newer"
                self.assertEqual(
                    response,
                    {
                        "jsonrpc": "2.0",
                        "error": {"code": -32602, "message": message},
                        "id": "unsupported-location",
                    } if json_rpc else {"result": message, "arguments": {}},
                )
                self.assertEqual(torrents[0]["downloadDir"], original_location)
                self.assertIsNone(server.state.last_torrent_set_location)
                self.assertEqual(
                    [event["phase"] for event in server.state.mutation_events],
                    ["submitted", "failed"],
                )

    def test_rename_records_running_between_submission_and_completion_in_both_envelopes(self) -> None:
        for json_rpc in (False, True):
            with self.subTest(json_rpc=json_rpc):
                torrents = mock.default_torrents()
                torrent_hash = torrents[0]["hashString"]
                with self.server(
                    torrents=torrents,
                    rpc_version_semver="6.0.0" if json_rpc else None,
                ) as server:
                    arguments = {
                        "ids": [torrent_hash],
                        "path": "Ubuntu ISO - downloading/README.txt",
                        "name": "NOTES.txt",
                    }
                    payload = (
                        {
                            "jsonrpc": "2.0",
                            "method": "torrent_rename_path",
                            "params": arguments,
                            "id": "rename",
                        }
                        if json_rpc
                        else {
                            "method": "torrent-rename-path",
                            "arguments": arguments,
                        }
                    )
                    response = self.post(server, payload)

                expected_result = {
                    "id": 1,
                    "path": "Ubuntu ISO - downloading/README.txt",
                    "name": "NOTES.txt",
                }
                self.assertEqual(
                    response,
                    {
                        "jsonrpc": "2.0",
                        "result": expected_result,
                        "id": "rename",
                    } if json_rpc else {
                        "result": "success",
                        "arguments": expected_result,
                    },
                )
                self.assertEqual(
                    [event["phase"] for event in server.state.mutation_events],
                    ["submitted", "running", "completed"],
                )
                self.assertIn(
                    "Ubuntu ISO - downloading/NOTES.txt",
                    [file["name"] for file in torrents[0]["files"]],
                )

    def test_one_shot_mutation_failures_use_native_envelopes_and_do_not_mutate_state(self) -> None:
        cases = {
            "torrent-verify": {},
            "torrent-set-location": {"location": "/srv/failure", "move": True},
            "torrent-rename-path": {
                "path": "Ubuntu ISO - downloading/README.txt",
                "name": "NOTES.txt",
            },
        }
        for method, extra_arguments in cases.items():
            for json_rpc in (False, True):
                with self.subTest(method=method, json_rpc=json_rpc):
                    torrents = mock.default_torrents()
                    torrent_hash = torrents[0]["hashString"]
                    expected_files = json.loads(json.dumps(torrents[0]["files"]))
                    expected_location = torrents[0]["downloadDir"]
                    failure = f"deterministic {method} failure"
                    with self.server(
                        torrents=torrents,
                        rpc_version_semver="6.0.0" if json_rpc else None,
                        mutation_failures={method: [failure]},
                    ) as server:
                        arguments = {"ids": [torrent_hash], **extra_arguments}
                        payload = (
                            {
                                "jsonrpc": "2.0",
                                "method": method.replace("-", "_"),
                                "params": arguments,
                                "id": "failure",
                            }
                            if json_rpc
                            else {"method": method, "arguments": arguments}
                        )
                        response = self.post(server, payload)

                    self.assertEqual(
                        response,
                        {
                            "jsonrpc": "2.0",
                            "error": {"code": -32602, "message": failure},
                            "id": "failure",
                        } if json_rpc else {"result": failure, "arguments": {}},
                    )
                    self.assertEqual(torrents[0]["status"], mock.STATUS_DOWNLOADING)
                    self.assertEqual(torrents[0]["downloadDir"], expected_location)
                    self.assertEqual(torrents[0]["files"], expected_files)
                    self.assertEqual(
                        [event["phase"] for event in server.state.mutation_events],
                        ["submitted", "failed"],
                    )
                    self.assertEqual(server.state.mutation_events[-1]["error"], failure)
                    self.assertEqual(server.state.mutation_failures, {})

    def test_rename_path_rejects_rpc_fourteen_through_the_standard_failure_envelope(self) -> None:
        torrents = mock.default_torrents()
        torrent_hash = torrents[0]["hashString"]
        with self.server(torrents=torrents, rpc_version=14) as server:
            response = self.post(server, {
                "method": "torrent-rename-path",
                "arguments": {
                    "ids": [torrent_hash],
                    "path": "Ubuntu ISO - downloading/README.txt",
                    "name": "NOTES.txt",
                },
            })

        message = "torrent-rename-path requires RPC version 15 or newer"
        self.assertEqual(response, {"result": message, "arguments": {}})
        self.assertEqual(
            [event["phase"] for event in server.state.mutation_events],
            ["submitted", "failed"],
        )

    def test_failure_option_parser_is_ordered_and_rejects_unsupported_methods(self) -> None:
        self.assertEqual(
            mock.parse_mutation_failures([
                "torrent-verify=first",
                "torrent-verify=second=with equals",
                "torrent-set-location=location failed",
            ]),
            {
                "torrent-verify": ["first", "second=with equals"],
                "torrent-set-location": ["location failed"],
            },
        )
        with self.assertRaisesRegex(SystemExit, "METHOD=MESSAGE"):
            mock.parse_mutation_failures(["torrent-remove=blocked"])


class DaemonMaintenanceFixtureTests(unittest.TestCase):
    def state(
        self,
        *,
        rpc_version: int = 18,
        port_is_open: bool = True,
        blocklist_size: int = 65_536,
    ) -> mock.MockState:
        session = mock.default_session()
        session["rpc-version"] = rpc_version
        return mock.MockState(
            session=session,
            torrents=[],
            session_id="maintenance-test-session",
            port_is_open=port_is_open,
            blocklist_size=blocklist_size,
        )

    def test_automatic_port_test_omits_protocol_from_response_and_state(self) -> None:
        state = self.state(port_is_open=False)

        self.assertEqual(state.port_test({}), {"port-is-open": False})
        snapshot = state.control_snapshot()
        self.assertIsNone(snapshot["lastPortTestProtocol"])
        self.assertFalse(snapshot["portIsOpen"])

    def test_explicit_port_protocol_is_validated_and_echoed(self) -> None:
        state = self.state()

        self.assertEqual(
            state.port_test({"ip-protocol": "ipv6"}),
            {"port-is-open": True, "ip-protocol": "ipv6"},
        )
        self.assertEqual(state.control_snapshot()["lastPortTestProtocol"], "ipv6")
        with self.assertRaisesRegex(ValueError, "ipv4 or ipv6"):
            state.port_test({"ip-protocol": "automatic"})
        with self.assertRaisesRegex(ValueError, "RPC version 18"):
            self.state(rpc_version=17).port_test({"ip-protocol": "ipv4"})

    def test_blocklist_update_is_nonnegative_and_counted(self) -> None:
        state = self.state(blocklist_size=0)

        self.assertEqual(state.blocklist_update({}), {"blocklist-size": 0})
        self.assertEqual(state.control_snapshot()["blocklistUpdateCount"], 1)
        with self.assertRaisesRegex(ValueError, "does not accept arguments"):
            state.blocklist_update({"unexpected": True})
        with self.assertRaisesRegex(ValueError, "non-negative"):
            self.state(blocklist_size=-1)

    def test_json_rpc_request_and_response_names_are_exact(self) -> None:
        method, arguments, request_id = mock.json_request_to_legacy({
            "jsonrpc": "2.0",
            "method": "port_test",
            "params": {"ip_protocol": "ipv4"},
            "id": 7,
        })
        self.assertEqual(method, "port-test")
        self.assertEqual(arguments, {"ip-protocol": "ipv4"})
        self.assertEqual(request_id, 7)
        self.assertEqual(
            mock.json_result(
                "port-test",
                {"port-is-open": True, "ip-protocol": "ipv4"},
            ),
            {"port_is_open": True, "ip_protocol": "ipv4"},
        )

        method, arguments, _ = mock.json_request_to_legacy({
            "jsonrpc": "2.0",
            "method": "blocklist_update",
            "params": {},
            "id": "blocklist",
        })
        self.assertEqual(method, "blocklist-update")
        self.assertEqual(arguments, {})
        self.assertEqual(
            mock.json_result("blocklist-update", {"blocklist-size": 42}),
            {"blocklist_size": 42},
        )


class TorrentRenamePathFixtureTests(unittest.TestCase):
    def state(self) -> mock.MockState:
        return mock.MockState(
            session=mock.default_session(),
            torrents=mock.default_torrents(),
            session_id="rename-test-session",
        )

    @staticmethod
    def file_names(state: mock.MockState, torrent_id: int = 1) -> list[str]:
        row = next(row for row in state.torrents if row["id"] == torrent_id)
        return [file["name"] for file in row["files"]]

    def test_legacy_file_rename_returns_exact_arguments_and_health(self) -> None:
        state = self.state()
        arguments = {
            "ids": [1],
            "path": "Ubuntu ISO - downloading/README.txt",
            "name": "NOTES.txt",
        }
        state.begin_request("torrent-rename-path", arguments, 128)
        try:
            result = state.rename_torrent_path(arguments)
        finally:
            state.end_request()

        self.assertEqual(
            mock.rpc_success_payload("torrent-rename-path", result, json_rpc=False),
            {
                "result": "success",
                "arguments": {
                    "id": 1,
                    "path": "Ubuntu ISO - downloading/README.txt",
                    "name": "NOTES.txt",
                },
            },
        )
        self.assertIn("Ubuntu ISO - downloading/NOTES.txt", self.file_names(state))
        self.assertNotIn("Ubuntu ISO - downloading/README.txt", self.file_names(state))
        snapshot = state.control_snapshot()
        self.assertEqual(snapshot["torrentRenamePathRequestCount"], 1)
        self.assertEqual(
            snapshot["lastTorrentRename"],
            {
                "id": 1,
                "path": "Ubuntu ISO - downloading/README.txt",
                "name": "NOTES.txt",
            },
        )
        self.assertEqual(set(snapshot["lastTorrentRename"]), {"id", "path", "name"})

    def test_json_rpc_envelope_normalizes_method_and_preserves_result_shape(self) -> None:
        state = self.state()
        method, arguments, request_id = mock.json_request_to_legacy({
            "jsonrpc": "2.0",
            "method": "torrent_rename_path",
            "params": {
                "ids": [1],
                "path": "Ubuntu ISO - downloading/payload.bin",
                "name": "image.iso",
            },
            "id": "rename-1",
        })

        self.assertEqual(method, "torrent-rename-path")
        self.assertEqual(
            arguments,
            {
                "ids": [1],
                "path": "Ubuntu ISO - downloading/payload.bin",
                "name": "image.iso",
            },
        )
        result = state.rename_torrent_path(arguments)
        self.assertEqual(
            mock.rpc_success_payload(
                method,
                result,
                json_rpc=True,
                request_id=request_id,
            ),
            {
                "jsonrpc": "2.0",
                "result": {
                    "id": 1,
                    "path": "Ubuntu ISO - downloading/payload.bin",
                    "name": "image.iso",
                },
                "id": "rename-1",
            },
        )

    def test_folder_rename_rewrites_only_that_folder_and_descendants(self) -> None:
        state = self.state()

        state.rename_torrent_path({
            "ids": 1,
            "path": "Ubuntu ISO - downloading/extras",
            "name": "samples",
        })

        self.assertEqual(
            self.file_names(state),
            [
                "Ubuntu ISO - downloading/README.txt",
                "Ubuntu ISO - downloading/payload.bin",
                "Ubuntu ISO - downloading/samples/sample.nfo",
            ],
        )

    def test_root_folder_rename_updates_torrent_name_and_all_file_prefixes(self) -> None:
        state = self.state()

        state.rename_torrent_path({
            "ids": [1],
            "path": "Ubuntu ISO - downloading",
            "name": "Ubuntu 24.04 ISO",
        })

        row = next(row for row in state.torrents if row["id"] == 1)
        self.assertEqual(row["name"], "Ubuntu 24.04 ISO")
        self.assertEqual(
            self.file_names(state),
            [
                "Ubuntu 24.04 ISO/README.txt",
                "Ubuntu 24.04 ISO/payload.bin",
                "Ubuntu 24.04 ISO/extras/sample.nfo",
            ],
        )

    def test_stable_hash_identifier_targets_one_torrent(self) -> None:
        state = self.state()
        row = next(row for row in state.torrents if row["id"] == 2)

        result = state.rename_torrent_path({
            "ids": row["hashString"],
            "path": "Fedora Workstation - seeding/README.txt",
            "name": "RELEASE.txt",
        })

        self.assertEqual(result["id"], 2)
        self.assertIn("Fedora Workstation - seeding/RELEASE.txt", self.file_names(state, 2))

    def test_collision_is_rejected_without_partial_mutation(self) -> None:
        state = self.state()
        before = self.file_names(state)

        with self.assertRaisesRegex(
            ValueError,
            "torrent-rename-path destination already exists",
        ):
            state.rename_torrent_path({
                "ids": [1],
                "path": "Ubuntu ISO - downloading/extras",
                "name": "README.txt",
            })

        self.assertEqual(self.file_names(state), before)
        self.assertIsNone(state.control_snapshot()["lastTorrentRename"])

    def test_malformed_names_are_rejected_consistently(self) -> None:
        for name in ("", ".", "..", "nested/name", "nested\\name", "bad\nname", "bad\x7fname"):
            with self.subTest(name=repr(name)):
                state = self.state()
                with self.assertRaisesRegex(
                    ValueError,
                    "torrent-rename-path name must be a non-empty single path component",
                ):
                    state.rename_torrent_path({
                        "ids": [1],
                        "path": "Ubuntu ISO - downloading/README.txt",
                        "name": name,
                    })

    def test_missing_and_noncanonical_paths_are_rejected(self) -> None:
        state = self.state()
        with self.assertRaisesRegex(ValueError, "torrent-rename-path path not found"):
            state.rename_torrent_path({
                "ids": [1],
                "path": "Ubuntu ISO - downloading/missing.txt",
                "name": "found.txt",
            })

        for path in ("", "/absolute", "folder/../file", "folder\\file", "folder//file", "bad\tpath"):
            with self.subTest(path=repr(path)):
                state = self.state()
                expected = (
                    "torrent-rename-path requires a non-empty path"
                    if not path
                    else "torrent-rename-path path must be a canonical relative path"
                )
                with self.assertRaisesRegex(ValueError, expected):
                    state.rename_torrent_path({"ids": [1], "path": path, "name": "valid"})

    def test_missing_torrent_and_non_single_targets_have_action_specific_errors(self) -> None:
        state = self.state()
        with self.assertRaisesRegex(ValueError, "torrent-rename-path torrent not found"):
            state.rename_torrent_path({
                "ids": [999],
                "path": "Ubuntu ISO - downloading/README.txt",
                "name": "NOTES.txt",
            })

        for ids_value in (None, [], [1, 2], [1, 999], True, 0):
            with self.subTest(ids=ids_value):
                state = self.state()
                arguments = {
                    "path": "Ubuntu ISO - downloading/README.txt",
                    "name": "NOTES.txt",
                }
                if ids_value is not None:
                    arguments["ids"] = ids_value
                with self.assertRaisesRegex(
                    ValueError,
                    "torrent-rename-path requires exactly one torrent identifier",
                ):
                    state.rename_torrent_path(arguments)

        message = "torrent-rename-path requires exactly one torrent identifier"
        self.assertEqual(
            mock.rpc_failure_payload(message, json_rpc=False),
            {"result": message, "arguments": {}},
        )
        self.assertEqual(
            mock.rpc_failure_payload(message, json_rpc=True, request_id="bad-rename"),
            {
                "jsonrpc": "2.0",
                "error": {"code": -32602, "message": message},
                "id": "bad-rename",
            },
        )

    def test_default_fixture_is_resettable_after_rename(self) -> None:
        changed = self.state()
        changed.rename_torrent_path({
            "ids": [1],
            "path": "Ubuntu ISO - downloading/README.txt",
            "name": "NOTES.txt",
        })

        reset = self.state()
        self.assertIn("Ubuntu ISO - downloading/README.txt", self.file_names(reset))
        self.assertIsNone(reset.control_snapshot()["lastTorrentRename"])
        self.assertEqual(reset.control_snapshot()["torrentRenamePathRequestCount"], 0)


if __name__ == "__main__":
    unittest.main()
