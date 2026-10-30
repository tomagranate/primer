#!/usr/bin/env bats

load '../../tests/helpers/common'

setup() {
    [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || skip 'Linux x86_64 release required'
    export HOME="$BATS_TEST_TMPDIR/home"
    export MOD_DIR="$PRIMER_DIR/modules/command-center-stream"
    mkdir -p "$HOME/.local/share/command-center-stream"
}

teardown() {
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}

@test "streaming bridge: real release serves its path and preserves state on repeated setup" {
    # Use a test identity. All release, config, and HTTP work uses the real binary.
    run zsh -c '
        source "$MOD_DIR/module.zsh"
        _command_center_stream::install_binary &&
        _command_center_stream::install_config test-machine 100.64.0.1
    '
    assert_success
    local dir="$HOME/.local/share/command-center-stream"
    local release="$dir/releases/3.0.1"
    run "$release/web-server" --config-path "$dir/config.json" config print
    assert_success
    printf '%s\n' "$output" | jq -e --arg data "$dir/data.json" '
        .data_storage.path == $data and
        .web_server.bind_address == "127.0.0.1:8791" and
        .web_server.url_path_prefix == "/stream/test-machine" and
        .web_server.forwarded_header.username_header == "X-CC-User" and
        .web_server.forwarded_header.auto_create_missing_user == true and
        .webrtc.ice_servers == [] and
        .webrtc.port_range == {min: 40000, max: 40010} and
        .webrtc.nat_1to1 == {ips: ["100.64.0.1"], ice_candidate_type: "host"} and
        .moonlight.pair_device_name == "command-center"
    '
    # Let the OS select a test HTTP port, without changing the installed config.
    (cd "$release" && exec ./web-server --config-path "$dir/config.json" --bind-address 127.0.0.1:0 run) > "$BATS_TEST_TMPDIR/server.log" 2>&1 &
    SERVER_PID=$!
    local address="" attempt
    for attempt in {1..100}; do
        address="$(sed -n 's/.*listening on: \(127\.0\.0\.1:[0-9]*\).*/\1/p' "$BATS_TEST_TMPDIR/server.log" | head -1)"
        [[ -n "$address" ]] && break
        sleep 0.1
    done
    [[ -n "$address" ]]
    run curl -fsS "http://$address/stream/test-machine/"
    assert_success
    assert_output --partial '<html'
    run curl -fsS -H 'X-CC-User: test-user' "http://$address/stream/test-machine/api/user"
    assert_success
    assert_output --partial 'test-user'
    # The running server creates real users and hosts storage, with no fake file.
    [[ -s "$dir/data.json" ]]
    sha256sum "$dir/data.json" "$dir/config.json" > "$BATS_TEST_TMPDIR/before.sha256"
    stat -c '%i %Y' "$release/web-server" "$dir/config.json" > "$BATS_TEST_TMPDIR/before.stat"
    rm -f "$dir/.restart-required"
    run zsh -c '
        source "$MOD_DIR/module.zsh"
        _command_center_stream::install_binary &&
        _command_center_stream::install_config test-machine 100.64.0.1
    '
    assert_success
    sha256sum --check "$BATS_TEST_TMPDIR/before.sha256"
    stat -c '%i %Y' "$release/web-server" "$dir/config.json" > "$BATS_TEST_TMPDIR/after.stat"
    cmp "$BATS_TEST_TMPDIR/before.stat" "$BATS_TEST_TMPDIR/after.stat"
    [[ ! -e "$dir/.restart-required" ]]
}
