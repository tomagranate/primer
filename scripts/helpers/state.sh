#!/usr/bin/env bash
## Collection of key system state variables

## Beekeeper Studio
BEEKEEPER_STUDIO_DB_SOURCE="$HOME/Library/Application Support/beekeeper-studio"
BEEKEEPER_STUDIO_DB_STORAGE="$REPO_ROOT/app-data/beekeeper-studio"

## iTerm
ITERM_CONFIG_SOURCE="$HOME/.app-config/iTerm"
ITERM_CONFIG_STORAGE="$REPO_ROOT/app-data/iterm"

## Firefox
firefoxProfilesFolder="$HOME/Library/Application Support/Firefox/Profiles"
FIREFOX_PROFILE_SOURCE=$(find "$firefoxProfilesFolder" -maxdepth 1 -type d -name "*.default-release")
FIREFOX_PROFILE_STORAGE="$REPO_ROOT/app-data/firefox"
