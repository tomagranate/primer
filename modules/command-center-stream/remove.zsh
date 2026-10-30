#!/bin/zsh
# Remove only the streaming bridge. Sunshine keeps its config and pairings.
set -euo pipefail

unit_dir="$HOME/.config/systemd/user"
if [[ -f "$unit_dir/command-center-stream.service" ]]; then
    systemctl --user disable --now command-center-stream.service
    rm -f "$unit_dir/command-center-stream.service"
    systemctl --user daemon-reload
fi
rm -rf "$HOME/.local/share/command-center-stream"
print 'Removed Command Center streaming, including its users and hosts.'
