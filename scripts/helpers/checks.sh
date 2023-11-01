#!/usr/bin/env bash
## Provides helpers to check the existence of commands and dependencies

source ./scripts/helpers/logging.sh

check () {
  verboseInfo "Checking for $1..."
  which $1 > /dev/null 2>&1
  if [ $? -ne 0 ]; then
    verboseWarning "$1 not found"
    return 1
  else
    verboseSuccess "$1 found"
    return 0
  fi
}

checkCommand () {
  verboseInfo "Checking for dependency with command: $1..."
  eval $1 > /dev/null 2>&1
  if [ $? -ne 0 ]; then
    verboseWarning "Dependency not found with command: $1"
    return 1
  else
    verboseSuccess "Dependency found with command: $1"
    return 0
  fi
}
