#!/bin/sh
# Remove one CI runner's workspace before and after every job.
set -eu

home="${GITHUB_CI_RUNNER_HOME:-/var/lib/github-ci-runner}"
instance="${1:-}"

if [ -n "$instance" ]; then
    case "$instance" in
        ''|.|..|*/*)
            echo "invalid CI runner instance" >&2
            exit 2
            ;;
    esac
    work="$home/$instance/_work"
else
    runner_home="${HOME:-}"
    case "$runner_home" in
        "$home"/*/_work/_home) ;;
        *)
            echo "refusing to clean an unexpected runner home" >&2
            exit 2
            ;;
    esac
    work="${runner_home%/_home}"
fi

case "$work" in
    "$home"/*/_work) ;;
    *)
        echo "refusing to clean an unexpected workspace" >&2
        exit 2
        ;;
esac

[ -d "$work" ] || exit 0
find "$work" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
mkdir -m 0700 "$work/_home"
