#!/usr/bin/env bash
set -euo pipefail

xcodegen generate

DEVICE_ID="$(xcrun simctl list devices available -j | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); print(next(device["udid"] for runtime in data["devices"].values() for device in runtime if device["name"].startswith("iPhone")))')"

xcodebuild test \
  -project SimpleCameraAutoSender.xcodeproj \
  -scheme SimpleCameraAutoSender \
  -destination "platform=iOS Simulator,id=${DEVICE_ID}" \
  CODE_SIGNING_ALLOWED=NO

