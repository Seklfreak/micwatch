#!/bin/bash
# Removes the launch agent and the installed binary.
# Keeps your config and log unless --purge is passed.
set -euo pipefail

LABEL="${MICWATCH_LABEL:-io.github.seklfreak.micwatch}"
PREFIX="${MICWATCH_PREFIX:-$HOME/Applications/MicWatch}"
CONFIG="${MICWATCH_CONFIG:-$HOME/.config/micwatch/config}"
LOG="${MICWATCH_LOG:-$HOME/Library/Logs/micwatch.log}"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null && echo "stopped launch agent" || echo "launch agent was not loaded"
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" && echo "removed plist"
rm -rf "$PREFIX" && echo "removed $PREFIX"

if [ "$PURGE" -eq 1 ]; then
  rm -f "$CONFIG" "$LOG"
  echo "removed config and log"
else
  echo "kept config ($CONFIG) and log ($LOG); pass --purge to remove them too"
fi
