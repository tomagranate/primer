#!/usr/bin/env bash
## Provides logging helper functions for scripts

success() {
  printf -- "\033[32m✔\033[0m  %s\n" "$1"
}

info() {
  printf -- "\033[36m➜\033[0m  %s\n" "$1"
}

warning() {
  printf -- "\033[33m⚠\033[0m  %s\n" "$1"
}

error() {
  printf -- "\033[31m✖\033[0m  %s\n" "$1"
}

verboseSuccess() {
  if [[ "$FLAG_VERBOSE" -ne 0 ]]; then
    printf -- "\033[32m✔\033[0m  %s\n" "$1"
  fi
}

verboseInfo() {
  if [[ "$FLAG_VERBOSE" -ne 0 ]]; then
    printf -- "\033[36m➜\033[0m  %s\n" "$1"
  fi
}

verboseError() {
  if [[ "$FLAG_VERBOSE" -ne 0 ]]; then
    printf -- "\033[31m✖\033[0m  %s\n" "$1"
  fi
}

verboseWarning() {
  if [[ "$FLAG_VERBOSE" -ne 0 ]]; then
    printf -- "\033[33m⚠\033[0m  %s\n" "$1"
  fi
}

fatal() {
  error "$*" >&2
  exit 1
}
