#!/bin/bash
# micwatch installer.
#
# Builds micwatch and installs it as a per-user launch agent. Everything lands
# inside your home directory: no sudo, no admin prompt, nothing system-wide.
#
# Usage:
#   ./install.sh                                   # prompts for webhook URLs
#   ./install.sh --start-url URL --end-url URL     # non-interactive
#
# Options:
#   --start-url URL   Home Assistant webhook to POST when the mic becomes active
#   --end-url URL     Home Assistant webhook to POST when the mic goes idle
#   --prefix PATH     install directory      (default ~/Applications/MicWatch)
#   --config PATH     config file location   (default ~/.config/micwatch/config)
#   --label NAME      launchd label          (default io.github.seklfreak.micwatch)
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="${MICWATCH_LABEL:-io.github.seklfreak.micwatch}"
PREFIX="${MICWATCH_PREFIX:-$HOME/Applications/MicWatch}"
CONFIG="${MICWATCH_CONFIG:-$HOME/.config/micwatch/config}"
LOG="${MICWATCH_LOG:-$HOME/Library/Logs/micwatch.log}"
START_URL=""
END_URL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --start-url) START_URL="$2"; shift 2 ;;
    --end-url)   END_URL="$2";   shift 2 ;;
    --prefix)    PREFIX="$2";    shift 2 ;;
    --config)    CONFIG="$2";    shift 2 ;;
    --label)     LABEL="$2";     shift 2 ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "$(id -u)" -eq 0 ]; then
  echo "Do not run this as root. micwatch installs entirely inside your home directory." >&2
  exit 1
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "micwatch is macOS only." >&2
  exit 1
fi

if ! xcrun -f swiftc >/dev/null 2>&1; then
  cat >&2 <<'MSG'
No Swift compiler found. micwatch is built from source and needs either Xcode or
the Xcode Command Line Tools.

  xcode-select --install

Note that installing the Command Line Tools requires administrator rights. If you
do not have them on this machine, stop here rather than looking for a workaround.
MSG
  exit 1
fi

# ── configuration ───────────────────────────────────────────────────────────
mkdir -p "$(dirname "$CONFIG")"
if [ -f "$CONFIG" ]; then
  echo "using existing config: $CONFIG"
else
  if [ -z "$START_URL" ] && [ -t 0 ]; then
    read -r -p "Home Assistant call-start webhook URL: " START_URL
  fi
  if [ -z "$END_URL" ] && [ -t 0 ]; then
    read -r -p "Home Assistant call-end webhook URL:   " END_URL
  fi
  if [ -z "$START_URL" ] || [ -z "$END_URL" ]; then
    echo "" >&2
    echo "No config found at $CONFIG." >&2
    echo "Either pass --start-url and --end-url, or copy config.example there and edit it." >&2
    exit 2
  fi
  ( umask 077
    cat > "$CONFIG" <<CFG
# micwatch configuration. Webhook URLs are secrets: keep this file out of git.
MICWATCH_START_URL=$START_URL
MICWATCH_END_URL=$END_URL

# Seconds the mic must stay idle before call-end fires (default 10).
# MICWATCH_IDLE_SECONDS=10

# Per-request curl timeout in seconds (default 2).
# MICWATCH_HTTP_TIMEOUT=2
CFG
  )
  echo "wrote config: $CONFIG"
fi
chmod 600 "$CONFIG"

# ── build ───────────────────────────────────────────────────────────────────
mkdir -p "$PREFIX"
echo "building micwatch..."
xcrun swiftc -O -swift-version 5 -o "$PREFIX/micwatch" "$SRC_DIR/micwatch.swift"
cp "$SRC_DIR/micwatch.swift" "$PREFIX/micwatch.swift"   # keep source next to the binary

echo ""
MICWATCH_CONFIG="$CONFIG" "$PREFIX/micwatch" --check
echo ""

# ── launch agent ────────────────────────────────────────────────────────────
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PREFIX/micwatch</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>MICWATCH_CONFIG</key>
        <string>$CONFIG</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
PLIST_EOF

plutil -lint "$PLIST" >/dev/null
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
echo "installed launch agent: $PLIST"

sleep 2
echo ""
launchctl print "gui/$UID/$LABEL" 2>/dev/null | grep -E '^[[:space:]]+(state|pid) =' || true
echo ""
echo "recent log ($LOG):"
tail -n 6 "$LOG" 2>/dev/null || echo "  (no output yet)"
echo ""
echo "Done. It starts automatically at login. Follow it with:"
echo "  tail -f $LOG"
