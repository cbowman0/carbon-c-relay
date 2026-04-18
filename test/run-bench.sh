#!/bin/bash
# carbon-c-relay benchmark runner
#
# Builds the benchmark Docker container (linux/amd64) and runs the benchmark
# inside it. All arguments are forwarded to bench.sh.
#
# Usage:
#   ./test/run-bench.sh [bench.sh options]
#
# Examples:
#   # Throughput benchmark, blackhole variant:
#   ./test/run-bench.sh --mode=throughput --variant=blackhole --metrics=1000000
#
#   # Run all throughput variants and compare:
#   ./test/run-bench.sh --mode=throughput --variant=blackhole   > baseline.txt
#   ./test/run-bench.sh --mode=throughput --variant=forward    >> baseline.txt
#   ./test/run-bench.sh --mode=throughput --variant=multiroute >> baseline.txt
#   ./test/run-bench.sh --mode=throughput --variant=snappy     >> baseline.txt
#   ./test/run-bench.sh --mode=throughput --variant=aggregate  >> baseline.txt
#
#   # AddressSanitizer correctness test:
#   ./test/run-bench.sh --mode=sanitize --sanitizer=asan
#
#   # ThreadSanitizer race detector:
#   ./test/run-bench.sh --mode=sanitize --sanitizer=tsan
#
#   # Malloc failure injection (tests B3, B5, B6, B7):
#   ./test/run-bench.sh --mode=sanitize --sanitizer=failmalloc
#
#   # CPU profile (requires --privileged):
#   ./test/run-bench.sh --mode=profile --variant=blackhole --privileged

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE_NAME="ccr-bench"
PLATFORM="linux/amd64"
PRIVILEGED=""
BENCH_ARGS=()

for arg in "$@"; do
    case $arg in
        --privileged) PRIVILEGED="--privileged" ;;
        *) BENCH_ARGS+=("$arg") ;;
    esac
done

echo "==> Building Docker image: $IMAGE_NAME (platform: $PLATFORM) ..."
docker build \
    --platform "$PLATFORM" \
    -f "$SCRIPT_DIR/Dockerfile.bench" \
    -t "$IMAGE_NAME" \
    "$REPO_DIR"

echo "==> Running benchmark inside container ..."
docker run \
    --platform "$PLATFORM" \
    --rm \
    $PRIVILEGED \
    "$IMAGE_NAME" \
    "${BENCH_ARGS[@]}"
