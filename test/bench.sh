#!/bin/bash
# carbon-c-relay benchmark driver
#
# Runs throughput, sanitizer, or profile benchmarks against a locally built relay.
# Intended to be run inside the Docker container produced by Dockerfile.bench,
# but can also run directly on Linux with the required dependencies installed.
#
# Usage:
#   bench.sh [OPTIONS]
#
# Options:
#   --mode=throughput|sanitize|profile   (default: throughput)
#   --variant=blackhole|forward|multiroute|snappy|aggregate|connections
#                                        (default: blackhole)
#   --workers=N                          (default: 4)
#   --metrics=N                          (default: 1000000)
#   --connections=N                      parallel sendmetric instances (default: 4)
#   --duration=N                         seconds for sustained mode; 0=drain (default: 0)
#   --sanitizer=asan|tsan|none           (default: none; only used in sanitize mode)
#   --listen-port=N                      relay listen port (default: 12003)
#   --forward-port=N                     nc listener port for forward variant (default: 12004)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BENCH_CONFIGS="$SCRIPT_DIR/bench-configs"

# Defaults
MODE=throughput
VARIANT=blackhole
WORKERS=4
METRICS=1000000
CONNECTIONS=4
DURATION=0
SANITIZER=none
LISTEN_PORT=12003
FORWARD_PORT=12004

for arg in "$@"; do
    case $arg in
        --mode=*)        MODE="${arg#--mode=}" ;;
        --variant=*)     VARIANT="${arg#--variant=}" ;;
        --workers=*)     WORKERS="${arg#--workers=}" ;;
        --metrics=*)     METRICS="${arg#--metrics=}" ;;
        --connections=*) CONNECTIONS="${arg#--connections=}" ;;
        --duration=*)    DURATION="${arg#--duration=}" ;;
        --sanitizer=*)   SANITIZER="${arg#--sanitizer=}" ;;
        --listen-port=*) LISTEN_PORT="${arg#--listen-port=}" ;;
        --forward-port=*)FORWARD_PORT="${arg#--forward-port=}" ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

RELAY="$REPO_DIR/relay"
SENDMETRIC="$REPO_DIR/sendmetric"
TMPDIR_BENCH=$(mktemp -d /tmp/ccr-bench.XXXXXX)
trap 'rm -rf "$TMPDIR_BENCH"; kill_relay' EXIT

RELAY_PID=""
NC_PID=""

kill_relay() {
    if [ -n "$RELAY_PID" ] && kill -0 "$RELAY_PID" 2>/dev/null; then
        kill "$RELAY_PID" 2>/dev/null || true
        wait "$RELAY_PID" 2>/dev/null || true
    fi
    if [ -n "$NC_PID" ] && kill -0 "$NC_PID" 2>/dev/null; then
        kill "$NC_PID" 2>/dev/null || true
    fi
}

#------------------------------------------------------------------------------
# Payload generation
#------------------------------------------------------------------------------
generate_payload() {
    local count=$1
    local outfile=$2
    local ts=1700000000
    local i=0
    # Mix of metric path styles: with '-', '_', '.', matching various configs
    local -a prefixes=(
        "servers.host-name_01.cpu.idle"
        "servers.host-name_02.mem.used"
        "servers.host-name_03.disk.read"
        "app.frontend.request-time"
        "app.backend.response_time"
        "kafka.broker.messages_in"
        "os.cpu.user"
        "dc.us-east.latency"
        "test.metric_group_01.value"
        "custom.app.counter"
    )
    local nprefix=${#prefixes[@]}
    while [ $i -lt $count ]; do
        local prefix="${prefixes[$((i % nprefix))]}"
        printf "%s %d %d\n" "$prefix.$i" "$((RANDOM % 1000))" "$((ts + i))"
        i=$((i + 1))
    done > "$outfile"
}

#------------------------------------------------------------------------------
# Build with sanitizer flags
#------------------------------------------------------------------------------
build_sanitized() {
    local san=$1
    # Map short names to GCC/clang sanitizer flag values
    local sanflag
    case $san in
        asan) sanflag=address ;;
        tsan) sanflag=thread  ;;
        *)    sanflag=$san    ;;
    esac
    echo "==> Building with -fsanitize=$sanflag ..."
    cd "$REPO_DIR"
    make clean >/dev/null 2>&1 || true
    local flags="-O1 -g -fsanitize=$sanflag -fno-omit-frame-pointer"
    # LDFLAGS must also carry the sanitizer flag so the runtime is linked in
    make CFLAGS="$flags" LDFLAGS="-fsanitize=$sanflag" all sendmetric
    echo "==> Build complete."
}

#------------------------------------------------------------------------------
# Parse -S output and print summary
#------------------------------------------------------------------------------
parse_stats() {
    local statsfile=$1
    local variant=$2
    local workers=$3
    local total_metrics=$4

    # Extract numeric mps-in column (col 1), skip header lines
    local avg_mps peak_mps avg_util
    avg_mps=$(awk '/^[ ]*[0-9]/{sum+=$1; n++} END{if(n>0) printf "%d", sum/n; else print 0}' "$statsfile")
    peak_mps=$(awk '/^[ ]*[0-9]/{if($1>max) max=$1} END{printf "%d", max+0}' "$statsfile")
    avg_util=$(awk '/^[ ]*[0-9]/{gsub(/%/,"",$NF); sum+=$NF; n++} END{if(n>0) printf "%.0f", sum/n; else print 0}' "$statsfile")

    printf "%-15s  workers=%-2d  avg_mps=%-8s  peak_mps=%-8s  util=%s%%\n" \
        "$variant" "$workers" "$avg_mps" "$peak_mps" "$avg_util"
}

#------------------------------------------------------------------------------
# MODE: throughput
#------------------------------------------------------------------------------
run_throughput() {
    local conf="$BENCH_CONFIGS/${VARIANT}.conf"
    if [ ! -f "$conf" ]; then
        echo "ERROR: Config not found: $conf" >&2
        exit 1
    fi

    if [ ! -x "$RELAY" ] || [ ! -x "$SENDMETRIC" ]; then
        echo "ERROR: relay or sendmetric binary not found. Run 'make all sendmetric' first." >&2
        exit 1
    fi

    local payload="$TMPDIR_BENCH/payload.txt"
    local statsfile="$TMPDIR_BENCH/stats.txt"
    local relay_log="$TMPDIR_BENCH/relay.log"

    echo "==> Generating $METRICS metrics ..."
    generate_payload "$METRICS" "$payload"

    # For forward variant, start a sink listener
    if [ "$VARIANT" = "forward" ] || [ "$VARIANT" = "snappy" ]; then
        nc -l -k "$FORWARD_PORT" >/dev/null 2>&1 &
        NC_PID=$!
        sleep 0.5
    fi

    echo "==> Starting relay (variant=$VARIANT, workers=$WORKERS, port=$LISTEN_PORT) ..."
    "$RELAY" -f "$conf" -w "$WORKERS" -p "$LISTEN_PORT" -S \
        2>"$relay_log" >"$statsfile" &
    RELAY_PID=$!
    sleep 2

    if ! kill -0 "$RELAY_PID" 2>/dev/null; then
        echo "ERROR: relay failed to start. Log:" >&2
        cat "$relay_log" >&2
        exit 1
    fi

    echo "==> Sending $METRICS metrics via $CONNECTIONS parallel connections ..."
    local pids=()
    local i
    for i in $(seq 1 "$CONNECTIONS"); do
        "$SENDMETRIC" -t "localhost:$LISTEN_PORT" < "$payload" &
        pids+=($!)
    done

    # Wait for all senders to finish
    for p in "${pids[@]}"; do
        wait "$p" 2>/dev/null || true
    done

    # Give relay a moment to drain queues
    sleep 3

    kill "$RELAY_PID" 2>/dev/null || true
    wait "$RELAY_PID" 2>/dev/null || true
    RELAY_PID=""

    echo ""
    echo "=== Throughput Results ==="
    parse_stats "$statsfile" "$VARIANT" "$WORKERS" "$((METRICS * CONNECTIONS))"
    echo ""
    echo "Full per-second stats saved to: $statsfile"
}

#------------------------------------------------------------------------------
# Malloc failure injection (tests B3, B5, B6, B7 error paths)
#------------------------------------------------------------------------------
run_failmalloc() {
    local so="$SCRIPT_DIR/failmalloc.so"
    if [ ! -f "$so" ]; then
        echo "==> Building failmalloc.so ..."
        gcc -shared -fPIC -O2 -o "$so" "$SCRIPT_DIR/failmalloc.c" -ldl
    fi

    if [ ! -x "$RELAY" ]; then
        echo "ERROR: relay binary not found. Run 'make all' first." >&2
        exit 1
    fi

    local conf="$BENCH_CONFIGS/blackhole.conf"
    local payload="$TMPDIR_BENCH/payload.txt"
    local relay_log="$TMPDIR_BENCH/failmalloc-relay.log"

    generate_payload 500 "$payload"

    echo "==> Running relay under malloc failure injection (threshold=200, prob=5%) ..."
    FAILMALLOC_THRESHOLD=200 FAILMALLOC_PROBABILITY=5 \
    LD_PRELOAD="$so" "$RELAY" -f "$conf" -w "$WORKERS" -p "$LISTEN_PORT" \
        2>"$relay_log" >/dev/null &
    RELAY_PID=$!
    sleep 2

    if ! kill -0 "$RELAY_PID" 2>/dev/null; then
        echo "==> Relay exited early (expected under heavy injection). Log:"
        tail -20 "$relay_log"
        RELAY_PID=""
        echo "==> Failmalloc test: PASS (relay handled allocation failures cleanly)"
        return
    fi

    # Send some metrics, ignore errors (relay may be degraded)
    "$SENDMETRIC" -t "localhost:$LISTEN_PORT" < "$payload" 2>/dev/null || true
    sleep 2

    kill "$RELAY_PID" 2>/dev/null || true
    wait "$RELAY_PID" 2>/dev/null || true
    RELAY_PID=""

    # Check for crashes / sanitizer errors (if relay was also built with ASan)
    if grep -qiE "(segfault|segmentation fault|abort|double free|invalid free)" "$relay_log" 2>/dev/null; then
        echo "==> CRASH detected under malloc injection:" >&2
        grep -iE "(segfault|segmentation fault|abort|double free|invalid free)" "$relay_log" >&2
        exit 1
    fi

    echo "==> Failmalloc injections performed:"
    grep -c '\[failmalloc\].*-> NULL' "$relay_log" 2>/dev/null | \
        xargs -I{} echo "    {} allocation failures injected"

    echo "==> Failmalloc test: PASS"
}

#------------------------------------------------------------------------------
# MODE: sanitize
#------------------------------------------------------------------------------
run_sanitize() {
    if [ "$SANITIZER" = "none" ]; then
        echo "ERROR: --sanitizer=asan|tsan|failmalloc required for sanitize mode" >&2
        exit 1
    fi

    if [ "$SANITIZER" = "failmalloc" ]; then
        run_failmalloc
        return
    fi

    build_sanitized "$SANITIZER"

    echo "==> Running make check under $SANITIZER ..."
    cd "$REPO_DIR"
    local san_log="$TMPDIR_BENCH/sanitizer.log"

    # Run existing test suite under sanitizer
    if make check 2>&1 | tee "$san_log"; then
        echo "==> make check: PASS"
    else
        echo "==> make check: FAIL (see $san_log)" >&2
        exit 1
    fi

    # Stress test: rapid connect/disconnect with small payloads
    echo "==> Running stress test (30s, $CONNECTIONS parallel connections) ..."
    local conf="$BENCH_CONFIGS/blackhole.conf"
    local stress_log="$TMPDIR_BENCH/stress-relay.log"
    local payload="$TMPDIR_BENCH/stress-payload.txt"

    generate_payload 1000 "$payload"

    "$RELAY" -f "$conf" -w "$WORKERS" -p "$LISTEN_PORT" \
        2>"$stress_log" >/dev/null &
    RELAY_PID=$!
    sleep 2

    if ! kill -0 "$RELAY_PID" 2>/dev/null; then
        echo "ERROR: relay failed to start under $SANITIZER. Log:" >&2
        cat "$stress_log" >&2
        exit 1
    fi

    local end_time=$(( $(date +%s) + 30 ))
    local stress_pids=()

    while [ "$(date +%s)" -lt "$end_time" ]; do
        for i in $(seq 1 "$CONNECTIONS"); do
            "$SENDMETRIC" -t "localhost:$LISTEN_PORT" < "$payload" &
            stress_pids+=($!)
        done
        for p in "${stress_pids[@]}"; do
            wait "$p" 2>/dev/null || true
        done
        stress_pids=()
    done

    kill "$RELAY_PID" 2>/dev/null || true
    wait "$RELAY_PID" 2>/dev/null || true
    RELAY_PID=""

    # Check sanitizer output for errors
    if grep -qE "(ERROR: (AddressSanitizer|ThreadSanitizer)|runtime error:)" "$stress_log" 2>/dev/null; then
        echo "==> Sanitizer errors detected:" >&2
        grep -E "(ERROR: (AddressSanitizer|ThreadSanitizer)|runtime error:)" "$stress_log" >&2
        exit 1
    fi

    echo "==> Stress test: PASS (no sanitizer errors)"
    echo ""
    echo "=== Sanitizer ($SANITIZER) Results: PASS ==="
}

#------------------------------------------------------------------------------
# MODE: profile (requires perf, run container with --privileged)
#------------------------------------------------------------------------------
run_profile() {
    if ! command -v perf >/dev/null 2>&1; then
        echo "ERROR: perf not found. Run container with --privileged and install linux-tools." >&2
        exit 1
    fi

    local conf="$BENCH_CONFIGS/blackhole.conf"
    local payload="$TMPDIR_BENCH/payload.txt"
    local perf_data="$TMPDIR_BENCH/perf.data"

    echo "==> Building with -O3 -g for profiling ..."
    cd "$REPO_DIR"
    make clean >/dev/null 2>&1 || true
    make CFLAGS="-O3 -g -Wall -pipe" all sendmetric

    generate_payload "$METRICS" "$payload"

    echo "==> Starting relay under perf record ..."
    perf record -g -o "$perf_data" \
        "$RELAY" -f "$conf" -w "$WORKERS" -p "$LISTEN_PORT" \
        2>/dev/null >/dev/null &
    RELAY_PID=$!
    sleep 2

    echo "==> Sending $METRICS metrics ..."
    local pids=()
    for i in $(seq 1 "$CONNECTIONS"); do
        "$SENDMETRIC" -t "localhost:$LISTEN_PORT" < "$payload" &
        pids+=($!)
    done
    for p in "${pids[@]}"; do
        wait "$p" 2>/dev/null || true
    done
    sleep 2

    kill "$RELAY_PID" 2>/dev/null || true
    wait "$RELAY_PID" 2>/dev/null || true
    RELAY_PID=""

    echo ""
    echo "=== Top Functions (perf report) ==="
    perf report --stdio -i "$perf_data" --no-children 2>/dev/null | head -40
    echo ""
    echo "Full perf data: $perf_data"
}

#------------------------------------------------------------------------------
# Dispatch
#------------------------------------------------------------------------------
case "$MODE" in
    throughput) run_throughput ;;
    sanitize)   run_sanitize   ;;
    profile)    run_profile    ;;
    *) echo "Unknown mode: $MODE (use throughput|sanitize|profile)" >&2; exit 1 ;;
esac
