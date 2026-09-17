#!/bin/bash
# Weekly re-install of YTRun to a physical iPhone over USB.
# Pulls latest from GitHub, builds for the connected device, installs, then cleans up
# build artifacts (but NOT the iOS platform/Simulator runtime: in this Xcode version
# that single package also provides the on-device build/deployment support, so
# deleting it breaks the next build and forces a ~17GB redownload).
set -euo pipefail

REPO_DIR="/Users/ranjithcv/Documents/code/claude/yt-run"
PROJECT="$REPO_DIR/YTRun/YTRun.xcodeproj"
SCHEME="YTRun"
# Built outside ~/Documents on purpose: that folder is synced by iCloud Drive
# (Desktop & Documents sync), which tags live build directories with Finder/
# file-provider metadata that codesign rejects ("resource fork, Finder
# information, or similar detritus not allowed"). Building in /tmp avoids it.
BUILD_DIR="/tmp/ytrun_build"

echo "==> Pulling latest code"
cd "$REPO_DIR"
git pull origin main

echo "==> Finding connected device"
# Table output's "Identifier" column is annotated (e.g. "<uuid> (UDID)"), which
# breaks whitespace-based parsing. Use --json-output instead and pull the real
# UDID from properties.hardware.udid - that's what xcodebuild's -destination
# expects (the top-level "identifier" field is a different CoreDevice UUID).
DEVICES_JSON="$(mktemp)"
trap 'rm -f "$DEVICES_JSON"' EXIT
xcrun devicectl list devices --json-output "$DEVICES_JSON" --omit-deprecated-fields-in-json >/dev/null
DEVICE_ID=$(jq -r '[.result.devices[] | select(.properties.connection.state == "connected")][0].properties.hardware.udid // empty' "$DEVICES_JSON")
if [ -z "$DEVICE_ID" ]; then
  echo "No connected device found. Plug in your iPhone via USB and unlock it." >&2
  exit 1
fi
echo "Using device: $DEVICE_ID"

echo "==> Clearing cached provisioning profiles"
# Free (personal-team) provisioning profiles are only valid 7 days, and
# the app stops launching when its profile expires. Xcode's automatic
# signing *reuses* a cached profile as long as it still has any validity
# left, so a mid-week reinstall would inherit the original expiry instead
# of getting a fresh 7 days. Deleting the cache forces Xcode to mint a new
# profile on every run, resetting the clock. Harmless with a paid account
# (those profiles just get regenerated with their normal 1-year validity).
rm -f ~/Library/MobileDevice/Provisioning\ Profiles/*.mobileprovision 2>/dev/null || true
rm -f ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision 2>/dev/null || true

echo "==> Building for device (no Simulator involved)"
# With the profile cache wiped above and two targets needing fresh profiles
# (YTRun app + YTRun.RunActivity extension), -allowProvisioningUpdates
# sometimes races: a packaging step reads a profile UUID just as it's being
# superseded by the other target's resolution, and fails with "Build input
# file cannot be found" for a .mobileprovision that never ends up on disk.
# The actual profile download/registration still succeeds, so a second
# attempt (profiles now cached) reliably works - retry once before giving up.
build_attempt() {
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "id=$DEVICE_ID" \
    -derivedDataPath "$BUILD_DIR" \
    -allowProvisioningUpdates
}

rm -rf "$BUILD_DIR"
if ! build_attempt; then
  echo "==> Build failed (likely a provisioning-profile resolution race after cache wipe); retrying once" >&2
  rm -rf "$BUILD_DIR"
  build_attempt
fi

APP_PATH=$(find "$BUILD_DIR/Build/Products" -maxdepth 2 -name "*.app" | head -1)
if [ -z "$APP_PATH" ]; then
  echo "Build succeeded but no .app bundle found under $BUILD_DIR/Build/Products" >&2
  exit 1
fi

echo "==> Installing $APP_PATH to device"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo "==> Cleaning up build artifacts"
rm -rf "$BUILD_DIR"

echo "==> Done. App installed on device. (iOS platform left intact - required for future builds.)"
