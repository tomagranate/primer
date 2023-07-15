#!/usr/bin/env bash
## Saves system state into this repository, so it can be pulled into a new system

# ------ Variable Initialization & Argument Parsing ------
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REPO_ROOT="$SCRIPT_DIR/.."

source $SCRIPT_DIR/helpers/state.sh
source $SCRIPT_DIR/helpers/logging.sh
source $SCRIPT_DIR/helpers/spinner.sh

## ---- Beekeeper Studio ----
mkdir -p "$BEEKEEPER_STUDIO_DB_STORAGE"
spin "Saving Beekeeper Studio state" cp "$BEEKEEPER_STUDIO_DB_SOURCE/app.db" "$BEEKEEPER_STUDIO_DB_STORAGE"

## ---- iTerm ----
mkdir -p "$ITERM_CONFIG_STORAGE"
spin "Saving iTerm state" rsync -a "$ITERM_CONFIG_SOURCE/" "$ITERM_CONFIG_STORAGE"

## ---- Firefox ----
mkdir -p "$FIREFOX_PROFILE_STORAGE"
spin "Saving Firefox state" cp "$FIREFOX_PROFILE_SOURCE/prefs.js" "$FIREFOX_PROFILE_STORAGE"


warning "You may need to add, commit, and push these changes to the repository"
success "System state saved successfully"
