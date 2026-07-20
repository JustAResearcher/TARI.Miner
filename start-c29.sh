#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARI_POOL="${TARI_POOL:-taric29-ca.luckypool.io:3111}"
TARI_WORKER="${TARI_WORKER:-$(hostname)}"
TARI_DEVICES="${TARI_DEVICES:-all}"
TARI_NVIDIA_SMI="${TARI_NVIDIA_SMI:-nvidia-smi}"
TARI_LOG_DIR="${TARI_LOG_DIR:-}"
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

stop_workers() {
    trap - INT TERM
    kill "${pids[@]}" 2>/dev/null || true
    wait "${pids[@]}" 2>/dev/null || true
    exit 130
}
trap stop_workers INT TERM

status=0
((missing == 0)) || status=1
for pid in "${pids[@]}"; do
    wait "$pid" || status=1
done
exit "$status"
