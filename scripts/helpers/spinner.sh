#!/usr/bin/env bash
## Helper function to provide a loading spinner while a command is running

## Spinner source: https://github.com/lnfnunes/bash-progress-indicator

export FRAME=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
export FRAME_INTERVAL=0.1

spin() {
  local label=$1
  shift
  local cmd
  for param in "$@"; do
    cmd+=" $param"
  done

  echo $cmd

  tput civis -- invisible
  local tmpfile=$(mktemp)

  # Run the command, saving output to a temporary file
  eval "${cmd}" > ${tmpfile} 2>&1 & pid=$!

  # Show a spinner while the command is running
  while ps -p $pid &>/dev/null; do
    echo -ne "\\r  ${label}"

    for k in "${!FRAME[@]}"; do
      echo -ne "\\r\033[36m${FRAME[k]}\033[0m"
      sleep $FRAME_INTERVAL
    done
  done

  wait $pid
  local exitcode=$?
  tput cnorm -- normal

  if [[ $exitcode -ne 0 ]]; then
    echo -ne "\\r\033[31m✖\033[0m  ${label}\\n"
    cat $tmpfile
    exit $exitcode
  fi
  
  echo -ne "\\r\033[32m✔\033[0m  ${label}\\n"
  if [[ "$VERBOSE" -ne 0 ]]; then
    cat $tmpfile
  fi
  rm $tmpfile
}
