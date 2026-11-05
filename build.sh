#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p dist
for lang in CZ EN; do
  name="Baterie BT"
  flags=()
  if [[ "$lang" == EN ]]; then name="BT Battery"; flags=(-D ENGLISH); fi
  app="dist/$lang/$name.app"
  mkdir -p "$app/Contents/MacOS"
  cp Info.plist "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $name" "$app/Contents/Info.plist"
  if [[ "$lang" == EN ]]; then
    /usr/libexec/PlistBuddy -c 'Set :NSBluetoothAlwaysUsageDescription Read Bluetooth mouse and keyboard battery levels.' "$app/Contents/Info.plist"
  fi
  for arch in arm64 x86_64; do
    xcrun swiftc -target "${arch}-apple-macos13.0" -module-cache-path "${TMPDIR:-/tmp}/bt-release-cache" ${flags[@]+"${flags[@]}"} \
      main.swift MiddlePaste.swift KeyboardSwitch.swift Localization.swift -framework Carbon \
      -o "dist/BaterieBT-$lang-$arch"
  done
  xcrun lipo -create "dist/BaterieBT-$lang-arm64" "dist/BaterieBT-$lang-x86_64" -output "$app/Contents/MacOS/BaterieBT"
  codesign --force --sign - -r '=designated => identifier "cz.local.bateriebt"' "$app"
  codesign --verify --strict "$app"
  ditto -c -k --keepParent "$app" "dist/BT-Battery-$lang.zip"
done
