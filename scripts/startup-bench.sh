#!/usr/bin/env bash
# Startup benchmark: our config vs clean nvim. min-of-3, wall clock.
# Usage: scripts/startup-bench.sh [bigfile]
set -u
cd "$(dirname "$0")/.." || exit 1

BIGFILE="${1:-/tmp/qa/big.json}"
if [ ! -f "$BIGFILE" ]; then
    python3 -c "print('[' + ','.join(['{\"k%d\":\"%s\"}' % (i, 'x'*40) for i in range(20000)]) + ']')" > "$BIGFILE"
fi

bench() {
    local label="$1"; shift
    local best=999999 t0 t1 dt
    for _ in 1 2 3; do
        t0=$(python3 -c "import time; print(int(time.time()*1000))")
        "$@" >/dev/null 2>&1
        t1=$(python3 -c "import time; print(int(time.time()*1000))")
        dt=$((t1 - t0))
        [ "$dt" -lt "$best" ] && best=$dt
    done
    printf "%-14s %4dms\n" "$label" "$best"
}

echo "== empty =="
bench "clean" nvim --clean --headless +qa
bench "ours" nvim --headless +qa
echo "== go file =="
bench "clean" nvim --clean --headless /tmp/qa/main.go +qa
bench "ours" nvim --headless /tmp/qa/main.go +qa
echo "== big file =="
bench "clean" nvim --clean --headless "$BIGFILE" +qa
bench "ours" nvim --headless "$BIGFILE" +qa
