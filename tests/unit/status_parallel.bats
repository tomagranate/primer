#!/usr/bin/env bats
# tests/unit/status_parallel.bats -- status checks execute in parallel

load '../helpers/common'

@test "run_status: executes module status checks in parallel" {
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        source \"\$PRIMER_DIR/lib/ui.zsh\"
        source \"\$PRIMER_DIR/lib/engine.zsh\"

        local fake_root
        fake_root=\"\$(mktemp -d)\"
        mkdir -p \"\$fake_root/lib\" \"\$fake_root/modules/one\" \"\$fake_root/modules/two\"
        cp \"${PRIMER_DIR}\"/lib/*.zsh \"\$fake_root/lib/\"

        cat > \"\$fake_root/primer.conf\" <<'EOF'
[one]
label = One

[two]
label = Two
EOF

        cat > \"\$fake_root/modules/one/module.zsh\" <<'EOF'
mod_status() {
    sleep 0.40
    primer::status_msg \"ok\"
    return 0
}
EOF

        cat > \"\$fake_root/modules/two/module.zsh\" <<'EOF'
mod_status() {
    sleep 0.40
    primer::status_msg \"ok\"
    return 0
}
EOF

        PRIMER_DIR=\"\$fake_root\"
        engine::load_config \"\$fake_root/primer.conf\"

        local start=\$EPOCHREALTIME
        engine::run_status >/dev/null
        local elapsed=\$(printf '%.3f' \$(( EPOCHREALTIME - start )))
        echo \"\$elapsed\"
    "
    assert_success

    # Parallel runtime should be close to one sleep, not the sum of two sleeps.
    # Sequential would be ~0.80s+; parallel should stay under 0.65s.
    awk -v t="$output" 'BEGIN { exit !(t < 0.65) }'
}

@test "status_msg: a concurrent reader never sees an empty status file" {
    # primer::status_msg must swap the file with a move. A plain redirect
    # truncates first, so a reader can catch the file while it holds no text.
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        source \"\$PRIMER_DIR/lib/ui.zsh\"
        export MOD_STATUS_FILE=\"\$(mktemp)\"
        primer::status_msg 'seed'

        (
            local i
            for (( i = 0; i < 600; i++ )); do
                primer::status_msg \"working \$i...\"
            done
        ) &
        local writer=\$!

        local reads=0 empty=0 text
        while kill -0 \$writer 2>/dev/null; do
            text=\"\$(cat \"\$MOD_STATUS_FILE\" 2>/dev/null)\"
            reads=\$(( reads + 1 ))
            [[ -z \"\$text\" ]] && empty=\$(( empty + 1 ))
        done
        wait \$writer
        rm -f \"\$MOD_STATUS_FILE\"
        print \"reads=\$reads empty=\$empty\"
    "
    assert_success
    assert_output --partial "empty=0"
    # The probe is only meaningful when it read the file while writes ran.
    local reads="${output#*reads=}"
    reads="${reads%% *}"
    (( reads > 0 )) || {
        echo "Expected the reader loop to run at least once: $output"; false
    }
}

@test "run_status: uses up to date fallback on empty success detail" {
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        source \"\$PRIMER_DIR/lib/ui.zsh\"
        source \"\$PRIMER_DIR/lib/engine.zsh\"

        local fake_root
        fake_root=\"\$(mktemp -d)\"
        mkdir -p \"\$fake_root/lib\" \"\$fake_root/modules/one\"
        cp \"${PRIMER_DIR}\"/lib/*.zsh \"\$fake_root/lib/\"

        cat > \"\$fake_root/primer.conf\" <<'EOF'
[one]
label = One
EOF

        cat > \"\$fake_root/modules/one/module.zsh\" <<'EOF'
mod_status() {
    # Intentionally successful with no status message.
    return 0
}
EOF

        PRIMER_DIR=\"\$fake_root\"
        source \"\$fake_root/lib/ui.zsh\"
        source \"\$fake_root/lib/engine.zsh\"
        engine::load_config \"\$fake_root/primer.conf\"

        engine::run_status
    "
    assert_success
    assert_output --partial "up to date"
    refute_output --partial "ok"
}

@test "run_status: renders all modules immediately while checks run" {
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        source \"\$PRIMER_DIR/lib/ui.zsh\"
        source \"\$PRIMER_DIR/lib/engine.zsh\"

        local fake_root
        fake_root=\"\$(mktemp -d)\"
        mkdir -p \"\$fake_root/lib\" \"\$fake_root/modules/one\" \"\$fake_root/modules/two\"
        cp \"${PRIMER_DIR}\"/lib/*.zsh \"\$fake_root/lib/\"

        cat > \"\$fake_root/primer.conf\" <<'EOF'
[one]
label = One

[two]
label = Two
EOF

        cat > \"\$fake_root/modules/one/module.zsh\" <<'EOF'
mod_status() {
    sleep 0.25
    primer::status_msg \"up to date\"
    return 0
}
EOF

        cat > \"\$fake_root/modules/two/module.zsh\" <<'EOF'
mod_status() {
    sleep 0.25
    primer::status_msg \"up to date\"
    return 0
}
EOF

        PRIMER_DIR=\"\$fake_root\"
        source \"\$fake_root/lib/ui.zsh\"
        source \"\$fake_root/lib/engine.zsh\"
        engine::load_config \"\$fake_root/primer.conf\"
        engine::run_status
    "
    assert_success
    assert_output --partial "One"
    assert_output --partial "Two"
    assert_output --partial "up to date"
}

@test "run_status: captured output does not emit live redraw escapes" {
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        source \"\$PRIMER_DIR/lib/ui.zsh\"
        source \"\$PRIMER_DIR/lib/engine.zsh\"

        local fake_root
        fake_root=\"\$(mktemp -d)\"
        mkdir -p \"\$fake_root/lib\" \"\$fake_root/modules/one\"
        cp \"${PRIMER_DIR}\"/lib/*.zsh \"\$fake_root/lib/\"

        cat > \"\$fake_root/primer.conf\" <<'EOF'
[one]
label = One
EOF

        cat > \"\$fake_root/modules/one/module.zsh\" <<'EOF'
mod_status() {
    sleep 0.10
    primer::status_msg \"ok\"
    return 0
}
EOF

        PRIMER_DIR=\"\$fake_root\"
        source \"\$fake_root/lib/ui.zsh\"
        source \"\$fake_root/lib/engine.zsh\"
        engine::load_config \"\$fake_root/primer.conf\"
        engine::run_status
    "
    assert_success
    refute_output --partial $'\e[2K'
    refute_output --partial $'\e[?25l'
    refute_output --partial $'\e[?25h'
}
