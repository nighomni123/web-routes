#!/bin/sh
set -eu

cd "$(dirname "$0")"
build=$(mktemp -d "${TMPDIR:-/private/tmp}/web-routes-build.XXXXXX")
trap 'rm -rf "$build"' EXIT
app="$build/Web Routes.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -O -module-cache-path "$build/modules" WebRoutes.swift -o "$app/Contents/MacOS/WebRoutes"
cp Info.plist "$app/Contents/Info.plist"
cp -R Companion "$app/Contents/Resources/"
cp native-host.py proxy.py firefox-prefs.js "$app/Contents/Resources/"
/usr/bin/codesign --force --sign - "$app"
mkdir -p "$HOME/Applications"
/usr/bin/ditto "$app" "$HOME/Applications/Web Routes.app"
/usr/bin/python3 - <<'PY'
import json
import os
import tempfile
from pathlib import Path

directory = Path.home() / "Library/Application Support/Mozilla/NativeMessagingHosts"
directory.mkdir(parents=True, exist_ok=True)
host = {
    "name": "local.web_routes.windows",
    "description": "Web Routes window selector",
    "path": str(Path.home() / "Applications/Web Routes.app/Contents/Resources/native-host.py"),
    "type": "stdio",
    "allowed_extensions": ["windows@web-routes.local"],
}
with tempfile.NamedTemporaryFile(mode="w", dir=directory, delete=False) as stream:
    json.dump(host, stream, indent=2)
os.replace(stream.name, directory / "local.web_routes.windows.json")
PY
