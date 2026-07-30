#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARI_POOL="${TARI_POOL:-taric29-ca.luckypool.io:3111}"
TARI_WORKER="${TARI_WORKER:-$(hostname)}"
TARI_DEVICES="${TARI_DEVICES:-all}"
TARI_NVIDIA_SMI="${TARI_NVIDIA_SMI:-nvidia-smi}"
TARI_LOG_DIR="${TARI_LOG_DIR:-}"
TARI_LOGIN_SEPARATOR="${TARI_LOGIN_SEPARATOR:-}"
MINER_ARGS=("$@")

if [[ -z "${TARI_WALLET:-}" ]]; then
    if [[ ! -t 0 ]]; then
        echo "ERROR: Set TARI_WALLET to your Tari wallet address." >&2
        exit 2
    fi
    echo "TARI.Miner C29 - community miner with no developer fee"
    echo "Pool: $TARI_POOL"
    read -r -p "Enter your Tari wallet address: " TARI_WALLET
fi

if [[ -z "$TARI_WALLET" ]]; then
    echo "ERROR: A wallet address is required." >&2
    exit 2
fi

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

device_selected() {
    local index="$1"
    local requested=",${TARI_DEVICES//[[:space:]]/},"
    [[ "${TARI_DEVICES,,}" == "all" || "$requested" == *",$index,"* ]]
}

backend_arch() {
    case "$1" in
        8.6) printf 'sm_86' ;;
        8.9) printf 'sm_89' ;;
        12.0) printf 'sm_120' ;;
        *) return 1 ;;
    esac
}

if ! gpu_output="$("$TARI_NVIDIA_SMI" --query-gpu=index,compute_cap,name --format=csv,noheader,nounits 2>&1)"; then
    echo "ERROR: nvidia-smi could not enumerate NVIDIA GPUs." >&2
    echo "$gpu_output" >&2
    exit 3
fi

detected=0
launched=0
missing=0
pids=()

while IFS=',' read -r raw_index raw_cap raw_name; do
    [[ -z "${raw_index//[[:space:]]/}" ]] && continue
    detected=$((detected + 1))
    index="$(trim "$raw_index")"
    cap="$(trim "$raw_cap")"
    name="$(trim "$raw_name")"

    device_selected "$index" || continue
    if ! arch="$(backend_arch "$cap")"; then
        echo "WARNING: Skipping GPU $index [$name]: compute capability $cap is not supported." >&2
        continue
    fi

    backend="$ROOT/bin/tari_c29_pool_miner_$arch"
    if [[ ! -x "$backend" ]]; then
        echo "ERROR: Missing $arch backend for GPU $index: $backend" >&2
        missing=$((missing + 1))
        continue
    fi

    gpu_worker="$TARI_WORKER-gpu$index"
    echo "GPU $index [$name] compute $cap -> $arch, worker $gpu_worker"
    command=("$backend" "${MINER_ARGS[@]}" --device "$index" --pool "$TARI_POOL" --wallet "$TARI_WALLET" --worker "$gpu_worker")
    if [[ -n "$TARI_LOGIN_SEPARATOR" ]]; then
        command+=(--login-separator "$TARI_LOGIN_SEPARATOR")
    fi
    if [[ "${TARI_DRY_RUN:-0}" == "1" ]]; then
        printf '[DRY RUN]'
        printf ' %q' "${command[@]}"
        printf '\n'
    elif [[ -n "$TARI_LOG_DIR" ]]; then
        mkdir -p "$TARI_LOG_DIR"
        log_file="$TARI_LOG_DIR/gpu$index.log"
        : > "$log_file"
        logged_command=("${command[@]}")
        if command -v stdbuf >/dev/null 2>&1; then
            logged_command=(stdbuf -oL -eL "${command[@]}")
        fi
        "${logged_command[@]}" > >(tee -a "$log_file") 2>&1 &
        pids+=("$!")
    else
        "${command[@]}" &
        pids+=("$!")
    fi
    launched=$((launched + 1))
done <<< "$gpu_output"

if ((detected == 0)); then
    echo "ERROR: No NVIDIA GPUs were detected." >&2
    exit 3
fi

if ((launched == 0)); then
    echo "ERROR: No supported GPUs matched TARI_DEVICES=$TARI_DEVICES." >&2
    exit 4
fi

echo "Started $launched miner worker(s) from $detected detected NVIDIA GPU(s)."
if [[ "${TARI_DRY_RUN:-0}" == "1" ]]; then
    ((missing == 0)) || exit 5
    exit 0
fi

kill_workers() {
    if ((${#pids[@]} > 0)); then
        local all_pids=("${pids[@]}")
        local survivors=("${pids[@]}")
        local pass pid
        kill "${all_pids[@]}" 2>/dev/null || true
        # A wedged miner must not hold the launcher (and therefore the rig
        # supervisor) forever. Give TERM two seconds, then force the survivors.
        for ((pass = 0; pass < 20 && ${#survivors[@]} > 0; pass++)); do
            sleep 0.1
            local remaining=()
            for pid in "${survivors[@]}"; do
                kill -0 "$pid" 2>/dev/null && remaining+=("$pid")
            done
            survivors=("${remaining[@]}")
        done
        if ((${#survivors[@]} > 0)); then
            kill -KILL "${survivors[@]}" 2>/dev/null || true
        fi
        wait "${all_pids[@]}" 2>/dev/null || true
        pids=()
    fi
}

stop_workers() {
    trap - INT TERM
    kill_workers
    exit 130
}
trap stop_workers INT TERM

status=0
((missing == 0)) || status=5

# A miner worker exits non-zero when it hits something only a restart can clear:
# a repeatedly rejected login (4), a failed solver (5), an unresponsive pool
# (6), or invalid pool protocol data (7). Stop the surviving workers and exit
# with that code, so a rig supervisor sees the failure instead of a launcher
# that keeps running its healthy GPUs.
worker_failure=0
while ((${#pids[@]} > 0)); do
    remaining=()
    for pid in "${pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            remaining+=("$pid")
            continue
        fi
        worker_status=0
        wait "$pid" || worker_status=$?
        if ((worker_status != 0)) && ((worker_failure == 0)); then
            echo "ERROR: GPU worker $pid exited with code $worker_status." >&2
            worker_failure="$worker_status"
        fi
    done
    pids=(${remaining[@]+"${remaining[@]}"})
    ((worker_failure == 0)) || break
    ((${#pids[@]} > 0)) || break
    sleep 1
done

if ((worker_failure != 0)); then
    if ((${#pids[@]} > 0)); then
        echo "Stopping ${#pids[@]} remaining GPU worker(s)." >&2
        kill_workers
    fi
    exit "$worker_failure"
fi

exit "$status"
