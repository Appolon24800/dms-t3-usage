#!/bin/sh
# Bring T3 Code to the front: focus its window on niri when it is open,
# otherwise launch it from its desktop entry.
#
# T3 Code's t3code:// links only handle pairing and sign-in, so there is no
# link that opens the Usage page directly.

APP_ID_PATTERN='com\.t3tools\.T3Code|t3code'

if [ -n "$NIRI_SOCKET" ] && command -v niri >/dev/null 2>&1; then
    id=$(niri msg --json windows 2>/dev/null | python3 -I -c '
import json, re, sys
try:
    windows = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for w in windows:
    if re.search(sys.argv[1], w.get("app_id") or "", re.I):
        print(w["id"])
        break
' "$APP_ID_PATTERN")
    if [ -n "$id" ]; then
        exec niri msg action focus-window --id "$id"
    fi
fi

# Not open (or not on niri): launch the first desktop entry that exists.
for entry in t3code com.t3tools.T3Code t3code-nightly t3-code; do
    for dir in "${XDG_DATA_HOME:-$HOME/.local/share}/applications" /usr/local/share/applications /usr/share/applications; do
        if [ -f "$dir/$entry.desktop" ] && ! grep -q '^NoDisplay=true' "$dir/$entry.desktop"; then
            exec gtk-launch "$entry"
        fi
    done
done

for bin in t3code t3code-nightly /opt/t3code-nightly-bin/t3code /opt/t3code-bin/t3code; do
    if command -v "$bin" >/dev/null 2>&1; then
        setsid "$bin" >/dev/null 2>&1 &
        exit 0
    fi
done

echo "T3 Code was not found" >&2
exit 1
