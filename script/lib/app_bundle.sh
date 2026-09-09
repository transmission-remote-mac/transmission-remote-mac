#!/usr/bin/env bash
# Transmission Remote Mac
# SPDX-FileCopyrightText: 2026 aidpok
# SPDX-License-Identifier: GPL-2.0-only
# See CREDITS.md for upstream attribution.

APP_EXECUTABLE_NAME="TransmissionRemoteMac"
APP_DISPLAY_NAME="Transmission Remote Mac"
APP_BUNDLE_ID="net.pokwer.TransmissionRemoteMac"
APP_MINIMUM_SYSTEM_VERSION="14.0"
APP_COPYRIGHT_NOTICE="Copyright © 2026 Transmission Remote Mac contributors"
APP_LOCAL_NETWORK_USAGE_DESCRIPTION="Connect to Transmission RPC servers on your local network."

load_app_metadata() {
  local root_dir="$1"
  local build_mode="${2:-development}"
  local version_file="$root_dir/VERSION"

  if [[ ! -f "$version_file" ]]; then
    echo "Missing canonical version file: $version_file" >&2
    return 1
  fi

  APP_VERSION="$(cat "$version_file")"
  if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must contain one three-component semantic version, for example 1.2.3." >&2
    return 1
  fi

  if [[ -n "${BUILD_NUMBER:-}" ]]; then
    APP_BUILD_NUMBER="$BUILD_NUMBER"
  elif [[ "$build_mode" == "release" ]]; then
    echo "Release builds require an explicit BUILD_NUMBER." >&2
    return 1
  else
    APP_BUILD_NUMBER="$(/usr/bin/git -C "$root_dir" rev-list --count HEAD)"
  fi

  if [[ ! "$APP_BUILD_NUMBER" =~ ^[0-9]{1,4}([.][0-9]{1,2}){0,2}$ ]]; then
    echo "BUILD_NUMBER must be one to three numeric components with Apple-compatible 4.2.2 digit limits." >&2
    return 1
  fi

  APP_ICON_PATH="$root_dir/Resources/AppIcon.icns"
  export APP_VERSION APP_BUILD_NUMBER APP_ICON_PATH
}

resolve_codesigning_identity_sha1() {
  local configured_identity="$1"
  local line
  local common_name
  local fingerprint
  local matched_fingerprint=""
  local match_count=0

  while IFS= read -r line; do
    fingerprint="$(printf '%s\n' "$line" | /usr/bin/awk '{print $2}')"
    common_name="${line#*\"}"
    common_name="${common_name%\"}"
    if [[ ${#fingerprint} == 40 \
       && "$fingerprint" != *[![:xdigit:]]* \
       && "$common_name" == "$configured_identity" ]]; then
      matched_fingerprint="$(printf '%s' "$fingerprint" | /usr/bin/tr '[:lower:]' '[:upper:]')"
      match_count=$((match_count + 1))
    fi
  done < <(/usr/bin/security find-identity -v -p codesigning 2>/dev/null)

  if [[ "$match_count" != 1 ]]; then
    echo "Signing identity must resolve to exactly one valid certificate: $configured_identity" >&2
    return 1
  fi

  printf '%s\n' "$matched_fingerprint"
}

extract_signed_leaf_fingerprints() {
  local bundle="$1"
  local output_dir="$2"
  local certificate="$output_dir/codesign0"

  /bin/rm -rf "$output_dir"
  /bin/mkdir -p "$output_dir"
  (
    cd "$output_dir"
    /usr/bin/codesign -d --extract-certificates "$bundle" >/dev/null 2>&1
  )
  if [[ ! -f "$certificate" ]]; then
    echo "Unable to extract the signed leaf certificate from: $bundle" >&2
    return 1
  fi

  SIGNED_LEAF_SHA1="$(/usr/bin/shasum -a 1 "$certificate" | /usr/bin/awk '{print toupper($1)}')"
  SIGNED_LEAF_SHA256="$(canonical_sha256 "$certificate")"
  export SIGNED_LEAF_SHA1 SIGNED_LEAF_SHA256
}

canonical_sha256() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print tolower($1)}'
}

verify_unsigned_bundle_xattrs() {
  local bundle="$1"
  local allowed_attribute="com.apple.provenance"
  local verification_dir
  local paths_file
  local names_file
  local item

  verification_dir="$(/usr/bin/mktemp -d "/tmp/transmission-xattr-verification.XXXXXX")"
  paths_file="$verification_dir/paths"
  names_file="$verification_dir/names"

  if ! /usr/bin/find "$bundle" -print0 >"$paths_file"; then
    /bin/rm -rf "$verification_dir"
    echo "Unable to enumerate unsigned app bundle items: $bundle" >&2
    return 1
  fi

  while IFS= read -r -d '' item; do
    if ! /usr/bin/xattr "$item" >"$names_file" 2>/dev/null; then
      /bin/rm -rf "$verification_dir"
      echo "Unable to inspect extended attributes for unsigned app bundle item: $item" >&2
      return 1
    fi
    if [[ -s "$names_file" ]] && \
       ! /usr/bin/cmp -s "$names_file" <(/usr/bin/printf '%s\n' "$allowed_attribute"); then
      /bin/rm -rf "$verification_dir"
      echo "Unsigned app bundle item contains attributes other than the allowed system provenance attribute: $item" >&2
      return 1
    fi
  done <"$paths_file"

  /bin/rm -rf "$verification_dir"
}

sanitize_and_verify_unsigned_bundle_xattrs() {
  local bundle="$1"

  /usr/bin/xattr -cr "$bundle"
  verify_unsigned_bundle_xattrs "$bundle"
}

write_app_info_plist() {
  local info_plist="$1"
  local icon_entry=""

  if [[ -f "$APP_ICON_PATH" ]]; then
    icon_entry='  <key>CFBundleIconFile</key>
  <string>AppIcon</string>'
  fi

  cat >"$info_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_EXECUTABLE_NAME</string>
  <key>CFBundleGetInfoString</key>
  <string>$APP_DISPLAY_NAME $APP_VERSION ($APP_BUILD_NUMBER)</string>
  $icon_entry
  <key>CFBundleIdentifier</key>
  <string>$APP_BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD_NUMBER</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>$APP_BUNDLE_ID.magnet</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>magnet</string>
      </array>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>BitTorrent File</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>torrent</string>
      </array>
      <key>CFBundleTypeMIMETypes</key>
      <array>
        <string>application/x-bittorrent</string>
      </array>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>org.bittorrent.torrent</string>
      </array>
    </dict>
  </array>
  <key>LSMinimumSystemVersion</key>
  <string>$APP_MINIMUM_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>$APP_COPYRIGHT_NOTICE</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>$APP_LOCAL_NETWORK_USAGE_DESCRIPTION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
}

assemble_app_bundle() {
  local root_dir="$1"
  local build_binary="$2"
  local app_bundle="$3"
  local contents="$app_bundle/Contents"
  local macos="$contents/MacOS"
  local resources="$contents/Resources"

  if [[ ! -x "$build_binary" ]]; then
    echo "Built executable is missing or not executable: $build_binary" >&2
    return 1
  fi

  /bin/mkdir -p "$macos" "$resources"
  /bin/cp -X "$build_binary" "$macos/$APP_EXECUTABLE_NAME"
  /bin/chmod +x "$macos/$APP_EXECUTABLE_NAME"

  write_app_info_plist "$contents/Info.plist"
  /usr/bin/plutil -lint "$contents/Info.plist" >/dev/null

  /bin/cp -X "$root_dir/LICENSE" "$resources/LICENSE"
  /bin/cp -X "$root_dir/CREDITS.md" "$resources/CREDITS.md"
  /bin/cp -X "$root_dir/PRIVACY.md" "$resources/PRIVACY.md"

  if [[ -f "$APP_ICON_PATH" ]]; then
    /bin/cp -X "$APP_ICON_PATH" "$resources/AppIcon.icns"
  fi
}
