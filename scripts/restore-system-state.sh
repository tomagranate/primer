#!/usr/bin/env bash
## Restores system state from this repository, pulling it into a new system

# ------ Variable Initialization & Argument Parsing ------
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REPO_ROOT="$SCRIPT_DIR/.."

source $SCRIPT_DIR/helpers/state.sh
source $SCRIPT_DIR/helpers/logging.sh
source $SCRIPT_DIR/helpers/spinner.sh

## ---- Beekeeper Studio ----
mkdir -p "$BEEKEEPER_STUDIO_DB_SOURCE"
spin "Restoring Beekeeper Studio state" cp "$BEEKEEPER_STUDIO_DB_STORAGE/app.db" "$BEEKEEPER_STUDIO_DB_SOURCE"

## ---- iTerm ----
mkdir -p "$ITERM_CONFIG_SOURCE"
spin "Restoring iTerm state" rsync -a "$ITERM_CONFIG_STORAGE/" "$ITERM_CONFIG_SOURCE"

## ---- Firefox ----
mkdir -p "$FIREFOX_PROFILE_SOURCE"
spin "Restoring Firefox state" cp "$FIREFOX_PROFILE_STORAGE/prefs.js" "$FIREFOX_PROFILE_SOURCE"


success "System state restored successfully"
