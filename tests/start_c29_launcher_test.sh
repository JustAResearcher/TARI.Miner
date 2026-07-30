#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tari-c29-launcher-test.XXXXXX")"
SURVIVOR_PID_FILE="$TEMP_ROOT/survivor.pid"

cleanup() {
    if [[ -f "$SURVIVOR_PID_FILE" ]]; then
        survivor_pid="$(cat "$SURVIVOR_PID_FILE")"
        if [[ "$survivor_pid" =~ ^[0-9]+$ ]]; then
            kill -KILL "$survivor_pid" 2>/dev/null || true
        fi
    fi
    rm -rf -- "$TEMP_ROOT"
}
trap cleanup EXIT

make_case() {
    local name="$1"
    local case_root="$TEMP_ROOT/$name"
    mkdir -p "$case_root/bin"
    cp "$ROOT/start-c29.sh" "$case_root/start-c29.sh"
    chmod +x "$case_root/start-c29.sh"
    printf '%s' "$case_root"
}

write_gpu_list() {
    local destination="$1"
    cat > "$destination" <<'EOF'
#!/usr/bin/env bash
printf '0, 12.0, Test GPU 0\n1, 8.9, Test GPU 1\n'
EOF
    chmod +x "$destination"
}

run_launcher() {
    local case_root="$1"
    set +e
    TARI_WALLET=test-login \
    TARI_NVIDIA_SMI="$case_root/nvidia-smi" \
    SURVIVOR_PID_FILE="$SURVIVOR_PID_FILE" \
        timeout 10s "$case_root/start-c29.sh" >"$case_root/output.log" 2>&1
    launcher_status=$?
    set -e
}

missing_root="$(make_case missing)"
write_gpu_list "$missing_root/nvidia-smi"
cat > "$missing_root/bin/tari_c29_pool_miner_sm_120" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$missing_root/bin/tari_c29_pool_miner_sm_120"
run_launcher "$missing_root"
if ((launcher_status != 5)); then
    cat "$missing_root/output.log"
    echo "expected missing backend exit 5, got $launcher_status" >&2
    exit 1
fi

wedged_root="$(make_case wedged)"
write_gpu_list "$wedged_root/nvidia-smi"
cat > "$wedged_root/bin/tari_c29_pool_miner_sm_120" <<'EOF'
#!/usr/bin/env bash
sleep 0.1
exit 5
EOF
cat > "$wedged_root/bin/tari_c29_pool_miner_sm_89" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" > "$SURVIVOR_PID_FILE"
while :; do sleep 1; done
EOF
chmod +x \
    "$wedged_root/bin/tari_c29_pool_miner_sm_120" \
    "$wedged_root/bin/tari_c29_pool_miner_sm_89"
run_launcher "$wedged_root"
if ((launcher_status != 5)); then
    cat "$wedged_root/output.log"
    echo "expected worker exit 5, got $launcher_status" >&2
    exit 1
fi
survivor_pid="$(cat "$SURVIVOR_PID_FILE")"
if kill -0 "$survivor_pid" 2>/dev/null; then
    cat "$wedged_root/output.log"
    echo "launcher left wedged worker $survivor_pid running" >&2
    exit 1
fi
rm -f -- "$SURVIVOR_PID_FILE"

echo "shell launcher regressions passed"
