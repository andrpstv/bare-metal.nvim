#!/usr/bin/env bash
# scripts/interactive-bench.sh — drive scripts/interactive-bench.lua inside a
# REAL UI-attached nvim (pty), and aggregate the post-paint curve.
#
# The single point of this script: make nvim_list_uis() > 0 genuinely true, so
# lua/distro/loader.lua's defer_enabled() gate opens and the interactive-only
# deferral paths actually run. Headless benchmarks cannot do this.
#
# Usage:
#   scripts/interactive-bench.sh [--reps N] [--sizes small,large] [--out FILE]
#
# Env:
#   NVIM_BENCH_CACHE   scratch dir for the generated Go corpus
#                      (default: $HOME/.cache/nvim-turbo-evidence)
#   NVIM_BENCH_REPS    repetitions per (condition, size)   (default 12)
#   NVIM_BENCH_KEEP    set to 0 to wipe the JSONL before running
set -uo pipefail

CONFIG_DIR="${NVIM_CONFIG_DIR:-$HOME/.config/nvim}"
CACHE_DIR="${NVIM_BENCH_CACHE:-$HOME/.cache/nvim-turbo-evidence}"
REPS="${NVIM_BENCH_REPS:-12}"
SIZES="small,large"
KEEP="${NVIM_BENCH_KEEP:-0}"

while [ $# -gt 0 ]; do
	case "$1" in
		--reps) REPS="$2"; shift 2 ;;
		--sizes) SIZES="$2"; shift 2 ;;
		--out) OUT="$2"; shift 2 ;;
		--cache) CACHE_DIR="$2"; shift 2 ;;
		-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
		*) echo "unknown arg: $1" >&2; exit 2 ;;
	esac
done

OUT="${OUT:-$CACHE_DIR/interactive-bench.jsonl}"
PROBE="$CONFIG_DIR/scripts/interactive-bench.lua"

command -v python3 >/dev/null || { echo "FATAL: python3 required" >&2; exit 2; }
[ -f "$PROBE" ] || { echo "FATAL: missing $PROBE" >&2; exit 2; }
command -v nvim >/dev/null || { echo "FATAL: nvim not on PATH" >&2; exit 2; }

mkdir -p "$CACHE_DIR"
# A run always starts from an empty JSONL. Appending to a previous run's data
# silently mixes conditions and breaks the per-(label,run) pairing, so the file
# is truncated unless NVIM_BENCH_KEEP=1 is set explicitly by the caller.
if [ "$KEEP" != "1" ]; then
	: > "$OUT"
	: > "$OUT.aborts"
fi

CORPUS="$CACHE_DIR/corpus"
mkdir -p "$CORPUS"

# --------------------------------------------------------------------- corpus
# Real Go-shaped source: imports, interfaces, structs with tags, error
# wrapping, goroutines + channels, defer, closures, generics, comments.
gen_go() {
	python3 - "$@" <<'PY'
import random, sys, io

def gen(path, n_lines, seed):
    rnd = random.Random(seed)
    o = io.StringIO()
    w = o.write
    pkgs = ["internal/store", "internal/transport", "internal/scheduler", "cmd/agent", "pkg/cache"]
    types = ["Config", "Record", "Envelope", "Segment", "Shard", "Session", "Ticket", "Cursor",
             "Lease", "Chunk", "Index", "Bloom", "Row", "Batch", "Journal", "Frame"]
    verbs = ["resolve", "flush", "compact", "reconcile", "expire", "publish", "drain", "replay",
             "coalesce", "rebalance", "annotate", "prune", "seal", "verify", "hydrate"]
    mods = ["sync", "context", "errors", "fmt", "io", "time", "sort", "strings", "encoding/json",
            "math", "os", "bytes", "strconv", "path/filepath", "hash/fnv", "log/slog"]

    w("package %s\n\n" % rnd.choice(pkgs).split("/")[-1])
    used = rnd.sample(mods, 5)
    w("import (\n")
    for m in used:
        w('\t"%s"\n' % m)
    w(")\n\n")

    w("// Err%s is returned when the %s invariant is violated.\n" % (rnd.choice(types), rnd.choice(types)))
    w("var Err%s = errors.New(\"%s: invariant violated\")\n\n" % (rnd.choice(types), rnd.choice(types).lower()))

    i = 0
    while len(o.getvalue().splitlines()) < n_lines - 60:
        i += 1
        t = rnd.choice(types)
        v = rnd.choice(verbs)
        arg = rnd.choice(types)
        style = i % 7
        if style == 0:
            w("type %s%d struct {\n" % (t, i))
            for f in range(rnd.randint(3, 6)):
                w('\t%s %s `json:"%s%s"`\n' % (
                    rnd.choice(["ID", "Seq", "TS", "TTL", "Depth", "Weight", "Flags", "Trace", "Shard", "Cursor"]),
                    rnd.choice(["uint64", "string", "time.Time", "int32", "[]byte", "map[string]string", "bool"]),
                    t.lower(), f))
            w("}\n\n")
        elif style == 1:
            w("type %sProvider%d interface {\n" % (t, i))
            w("\tFetch(ctx context.Context, id string) (%s%d, error)\n" % (t, i))
            w("\tStream(ctx context.Context, ch chan<- %s%d, batch int) error\n" % (t, i))
            w("\tClose() error\n}\n\n")
        elif style == 2:
            w("func %s%s%d(ctx context.Context, in %s%d, opts ...func(*%s%d)) error {\n"
              % (v, t, i, arg, i, t, i))
            w("\tstart := time.Now()\n")
            w("\tdefer func() {\n\t\tslog.Debug(\"%s%d done\", \"d\", time.Since(start))\n\t}()\n" % (v, i))
            w("\tselect {\n\tcase <-ctx.Done():\n\t\treturn ctx.Err()\n\tdefault:\n\t}\n")
            for k in range(rnd.randint(2, 5)):
                w("\tif len(in.%s) > %d {\n\t\treturn fmt.Errorf(\"%s: %%w\", Err%s)\n\t}\n"
                  % (rnd.choice(["ID", "Trace", "Cursor"]), k * 8, v, rnd.choice(types)))
            w("\tfor i := 0; i < %d; i++ {\n" % rnd.randint(2, 6))
            w("\t\tif i%%2 == 0 {\n\t\t\tcontinue\n\t\t}\n")
            w("\t\tin.ID = in.ID + strconv.FormatInt(int64(i), 10)\n\t}\n")
            w("\treturn nil\n}\n\n")
        elif style == 3:
            w("func %s%s%d(ctx context.Context, mu *sync.Mutex, in <-chan %s%d) error {\n"
              % (v, t, i, t, i))
            w("\tmu.Lock()\n\tdefer mu.Unlock()\n")
            w("\tfor {\n\t\tselect {\n\t\tcase <-ctx.Done():\n\t\t\treturn nil\n")
            w("\t\tcase v, ok := <-in:\n\t\t\tif !ok {\n\t\t\t\treturn nil\n\t\t\t}\n")
            w("\t\t\t_ = v\n\t\t}\n\t}\n}\n\n")
        elif style == 4:
            w("// %s computes the %s for id using a %s-backed cache.\n" % (v, t, t.lower()))
            w("func %s%s%d(id string) (%s%d, error) {\n" % (v, t, i, t, i))
            w("\th := fnv.New64a()\n\t_, _ = h.Write([]byte(id))\n")
            w("\tsum := h.Sum64()\n\tif sum%%2 == 0 {\n\t\treturn %s%d{}, nil\n\t}\n" % (t, i))
            w("\treturn %s%d{}, Err%s\n}\n\n" % (t, i, rnd.choice(types)))
        elif style == 5:
            w("func %s%s%d[T ~string | ~int](vals []T, pred func(T) bool) []T {\n" % (v, t, i))
            w("\tout := make([]T, 0, len(vals))\n")
            w("\tfor _, v := range vals {\n\t\tif pred(v) {\n\t\t\tout = append(out, v)\n\t\t}\n\t}\n")
            w("\tsort.Slice(out, func(a, b int) bool { return fmt.Sprint(out[a]) < fmt.Sprint(out[b]) })\n")
            w("\treturn out\n}\n\n")
        else:
            w("// %s reports metrics for the %s pipeline stage %d.\n" % (v, t, i))
            w("func %s%s%d() map[string]int {\n" % (v, t, i))
            w("\tout := make(map[string]int, %d)\n" % rnd.randint(2, 5))
            w("\tfor i := 0; i < %d; i++ {\n\t\tout[fmt.Sprintf(\"shard-%%d\", i%%16)] += i\n\t}\n" % rnd.randint(2, 5))
            w("\treturn out\n}\n\n")

    tail = [
        "func init() {",
        "\tslog.SetDefault(slog.Default().With(\"component\", \"%s\"))" % rnd.choice(pkgs),
        "}",
        "",
    ]
    w("\n".join(tail) + "\n")
    txt = o.getvalue().splitlines()
    while len(txt) < n_lines:
        txt.append("")
    with open(path, "w") as f:
        f.write("\n".join(txt[:n_lines]) + "\n")

gen(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]))
PY
}

if [ ! -s "$CORPUS/small_1k.go" ]; then
	gen_go "$CORPUS/small_1k.go" 1000 11
	gen_go "$CORPUS/large_12k.go" 12000 42
	echo "corpus:"
	wc -l "$CORPUS/small_1k.go" "$CORPUS/large_12k.go"
fi

# gopls needs a module, otherwise it stays in degraded single-file mode
# ("No packages found") and every Go measurement times out instead of
# measuring the distro. Imports inside the corpus are intentionally fake —
# the server stays alive and answers local queries, which is what we bench.
if [ ! -s "$CORPUS/go.mod" ]; then
	printf 'module benchcorpus\n\ngo 1.21\n' >"$CORPUS/go.mod"
	echo "corpus: wrote $CORPUS/go.mod"
fi

file_for_size() {
	case "$1" in
		small) echo "$CORPUS/small_1k.go" ;;
		large) echo "$CORPUS/large_12k.go" ;;
		*) echo "FATAL: bad size $1" >&2; exit 2 ;;
	esac
}

# ------------------------------------------------------------------- pty core
# Run a command with a REAL controlling terminal: python3 openpty(), parent
# drains the master so the child's pty buffer never fills, stdin is the pty
# (not /dev/null — an EOF on stdin would SIGHUP the child immediately).
pty_run() {
	python3 - "$@" <<'PY'
import os, pty, sys, threading, time

argv = sys.argv[1:]
master, slave = pty.openpty()
# Make the pty big enough that a full-screen TUI redraw cannot block on write.
try:
    import fcntl, termios, struct
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 200, 0, 0))
except Exception:
    pass
os.set_blocking(master, False)
env = dict(os.environ)
env.setdefault("TERM", "xterm-256color")

p = subprocess_popen = __import__("subprocess").Popen(
    argv, stdin=slave, stdout=slave, stderr=slave, env=env, close_fds=True
)
os.close(slave)

stop = threading.Event()

def drain():
    while not stop.is_set():
        try:
            data = os.read(master, 65536)
            if not data:
                break
        except (BlockingIOError, InterruptedError):
            time.sleep(0.005)
        except OSError:
            break

th = threading.Thread(target=drain, daemon=True)
th.start()
try:
    rc = p.wait(timeout=float(os.environ.get("IBENCH_TIMEOUT", "60")))
except Exception:
    p.kill()
    rc = 124
stop.set()
try:
    os.close(master)
except OSError:
    pass
sys.exit(rc)
PY
}

# ----------------------------------------------------------------- conditions
# Four conditions, back to back, interleaved by repetition so machine drift
# (thermal, background jobs) hits every condition equally instead of
# penalising whichever one ran last.
#
# (a) clean      nvim -u NONE — the floor: what a bare editor costs.
# (b) distro-off full distro, perf NOT set: deferral is live (UI attached)
#     but perf_defer's own micro-optimisations (khold-on-idle, lazy gitsigns attach,
#     2-Lua-callback cursorline, deferred pairs) follow the single D flag.
#     (Post 4->2 the loader + micro-opts share NVIM_PERF_DEFER; there is no
#     separate "loader on / micro off" state anymore.)
# (c) distro-turbo  NVIM_PERF_DEFER=1 — the branch under test.
#     (NVIM_TURBO=1 kept as deprecated fallback in core/perf.)
# (d) clean-ts   nvim -u NONE + the vendored nvim-treesitter ONLY, started on
#     BufReadPre for *.go. THIS IS THE ISOLATED MECHANISM: it is the single
#     size-dependent cost in the whole curve. If the Go parse is ~N ms at 1k
#     lines and ~M ms at 12k lines, the "large files are disproportionately
#     slow" report is explained by parsing, not by the distro loader — and
#     perf_defer can only *move* that cost after paint, never remove it.
#     (Chosen over an NVIM_DISTRO_SYNC=1 control because SYNC also flips
#     core.perf.defer_on() to false, so it would conflate deferral with four
#     unrelated perf code paths.)

run_one() {
	local label="$1" file="$2" idx="$3"
	# NOTE: no `--cmd` here on purpose. An extra `--cmd 'set ...'` startup
	# command was observed to stall nvim's event loop under the pty
	# (deferred timers fired ~25s late, which would have produced garbage
	# measurements). Determinism options (no swapfile/shada) are set inside
	# the probe AFTER the UI attaches, so they cannot perturb startup.
	# NOTE: bash 3.2 + `set -u` treats an empty array as unbound, hence the
	# ${arr[@]+"${arr[@]}"} guard below.
	local envs=()
	local -a args=()
	case "$label" in
		clean)        envs=(NVIM_DISTRO_SYNC=1);               args=(-u NONE) ;;
		distro-off)   envs=(NVIM_PERF_DEFER=0);                 args=(-u "$CONFIG_DIR/init.lua") ;;
		distro-turbo) envs=(NVIM_PERF_DEFER=1);                args=(-u "$CONFIG_DIR/init.lua") ;;
		clean-ts)     envs=(NVIM_DISTRO_SYNC=1 IBENCH_TS=1);    args=(-u NONE) ;;
		*) echo "FATAL: bad label $label" >&2; exit 2 ;;
	esac

	pty_run env -u NVIM_PERF_DEFER -u NVIM_PERF_LEAN -u NVIM_TURBO -u NVIM_TURBO_MODE -u NVIM_WEAK_HW -u NVIM_DISTRO_SYNC \
	    ${envs[@]+"${envs[@]}"} \
	    IBENCH_OUT="$OUT" IBENCH_FILE="$file" IBENCH_LABEL="$label" IBENCH_RUN="$idx" \
	    IBENCH_TIMEOUT=60 \
	    nvim -i NONE "${args[@]}" \
	    -c "luafile $PROBE" >/dev/null 2>&1
	local rc=$?
	if [ $rc -ne 0 ]; then
		echo "  !! run aborted rc=$rc (label=$label run=$idx)" >&2
		return 1
	fi
	return 0
}

echo "interactive-bench: reps=$REPS sizes=$SIZES out=$OUT"
: > "$OUT.aborts"

IFS=',' read -r -a SIZE_LIST <<< "$SIZES"
for ((i = 0; i < REPS; i++)); do
	for size in "${SIZE_LIST[@]}"; do
		file="$(file_for_size "$size")"
		for label in clean distro-off distro-turbo clean-ts; do
			printf '  rep %2d/%s  %-13s %-6s ... ' "$((i + 1))" "$REPS" "$label" "$size"
			if run_one "$label" "$file" "$i"; then
				echo "ok"
			else
				grep "\"abort\"" "$OUT" | tail -1 >> "$OUT.aborts" 2>/dev/null || true
			fi
		done
	done
done

# ---------------------------------------------------------------- aggregation
echo
echo "=== statistics ==="
python3 - "$OUT" <<'PY'
import json, math, statistics, sys, collections

path = sys.argv[1]
rows = [json.loads(l) for l in open(path) if l.strip()]
if not rows:
    print("NO DATA — every run aborted. Refusing to print an empty table.")
    sys.exit(1)

def stats(xs):
    if not xs: return None
    xs = sorted(xs)
    n = len(xs)
    def pct(p):
        if n == 1: return xs[0]
        k = (n - 1) * p
        f, c = math.floor(k), math.ceil(k)
        return xs[f] if f == c else xs[f] + (xs[c] - xs[f]) * (k - f)
    return dict(n=n, min=xs[0], median=statistics.median(xs), p90=pct(.90),
                p95=pct(.95), max=xs[-1],
                mean=round(statistics.fmean(xs), 2),
                stddev=round(statistics.stdev(xs), 2) if n > 1 else 0.0)

samples = [r for r in rows if r.get("kind") == "sample" and r.get("lag_ms") is not None]
dones   = [r for r in rows if r.get("kind") == "done"]
aborts  = [r for r in rows if r.get("kind") == "abort"]

print(f"runs completed: {len(dones)}   samples: {len(samples)}   aborts: {len(aborts)}")
for a in aborts[:5]:
    print("  ABORT:", a.get("label"), a.get("run"), a.get("reason"))

labels = ["clean", "distro-off", "distro-turbo", "clean-ts"]
sizes  = sorted({r.get("lines") or 0 for r in samples if r.get("lines")},
                key=lambda s: s)
size_of = {}
for r in samples:
    if r.get("lines"): size_of[(r["label"], r["run"])] = r["lines"]

print("\n### A. Event-loop lag at each sample point (ms) — the post-paint cliff")
print("lag = actual callback time - nominal schedule; positive burst == main loop blocked")
for size in sizes:
    print(f"\n-- file size: {size} lines --")
    print(f"{'condition':<14}{'t':>6}{'n':>4}{'min':>8}{'median':>9}{'p90':>9}{'p95':>9}{'max':>9}{'stddev':>9}")
    for lab in labels:
        for t in (0, 100, 300, 1000):
            xs = [r["lag_ms"] for r in samples
                  if r["label"] == lab and r["t_ms"] == t
                  and size_of.get((lab, r["run"]), size) == size]
            s = stats(xs)
            if not s: continue
            print(f"{lab:<14}{t:>6}{s['n']:>4}{s['min']:>8.1f}{s['median']:>9.1f}"
                  f"{s['p90']:>9.1f}{s['p95']:>9.1f}{s['max']:>9.1f}{s['stddev']:>9.1f}")

print("\n### B. Plugins loaded in the loader registry (count) at each sample point")
print(f"{'condition':<14}{'size':>7}{'t':>6}{'n':>4}{'min':>6}{'median':>9}{'p95':>9}{'max':>6}{'stddev':>9}")
for size in sizes:
    for lab in labels:
        for t in (0, 100, 300, 1000):
            xs = [r["plugins"] for r in samples
                  if r["label"] == lab and r["t_ms"] == t
                  and size_of.get((lab, r["run"]), size) == size]
            xs = [x for x in xs if x >= 0]
            s = stats(xs)
            if not s: continue
            print(f"{lab:<14}{size:>7}{t:>6}{s['n']:>4}{s['min']:>6}{s['median']:>9.1f}"
                  f"{s['p95']:>9.1f}{s['max']:>6}{s['stddev']:>9.1f}")

print("\n### C. File-open leg: harness-ready -> BufReadPost (ms)")
print(f"{'condition':<14}{'size':>7}{'n':>4}{'min':>8}{'median':>9}{'p90':>9}{'p95':>9}{'max':>9}{'stddev':>9}")
for size in sizes:
    for lab in labels:
        xs = [d["boot_to_bufread_ms"] for d in dones
              if d["label"] == lab and d.get("boot_to_bufread_ms", -1) >= 0
              and size_of.get((lab, d["run"]), size) == size]
        s = stats(xs)
        if not s: continue
        print(f"{lab:<14}{size:>7}{s['n']:>4}{s['min']:>8.1f}{s['median']:>9.1f}"
              f"{s['p90']:>9.1f}{s['p95']:>9.1f}{s['max']:>9.1f}{s['stddev']:>9.1f}")

print("\n### D. Deferred-work state at t=1000ms (fraction of runs, and 95% CI half-width)")
print(f"{'condition':<14}{'size':>7}{'gitsigns_attach':>17}{'lsp>0':>9}{'ts_parser':>12}{'deferral_inert':>17}{'plugins_0->1000':>18}")
for size in sizes:
    for lab in labels:
        sel = [r for r in samples if r["label"] == lab and r["t_ms"] == 1000
               and size_of.get((lab, r["run"]), size) == size]
        if not sel: continue
        n = len(sel)
        def frac(pred):
            k = sum(1 for r in sel if pred(r))
            p = k / n
            return f"{k}/{n}={p:.0%}" + ("" if n < 4 else f"±{1.96*math.sqrt(max(p*(1-p),1e-9)/n):.0%}")
        gs = frac(lambda r: r.get("gitsigns_attached"))
        ls = frac(lambda r: (r.get("lsp_clients") or 0) > 0)
        ts = frac(lambda r: r.get("ts_parser"))
        dl = frac(lambda r: False)  # placeholder, filled from done records
        dn = [d for d in dones if d["label"] == lab and size_of.get((lab, d["run"]), size) == size]
        if dn:
            inert = sum(1 for d in dn if d.get("deferral_inert"))
            dl = f"{inert}/{len(dn)}"
            p0 = statistics.median([d["plugins_first"] for d in dn])
            p1 = statistics.median([d["plugins_last"] for d in dn])
            delta = f"{p0:.0f}->{p1:.0f}"
        else:
            delta = "-"
        print(f"{lab:<14}{size:>7}{gs:>17}{ls:>9}{ts:>12}{dl:>17}{delta:>18}")

print("\n### E. Per-change verdict inputs (median lag at t=300, by size)")
for size in sizes:
    print(f"\n-- {size} lines --")
    for lab in labels:
        xs = [r["lag_ms"] for r in samples if r["label"] == lab and r["t_ms"] == 300
              and size_of.get((lab, r["run"]), size) == size]
        s = stats(xs)
        if s: print(f"  {lab:<14} n={s['n']:<3} median={s['median']:.1f} p95={s['p95']:.1f} max={s['max']:.1f} stddev={s['stddev']:.1f}")

# raw dump for the evidence doc
raw = collections.defaultdict(list)
for r in sorted(samples, key=lambda r: (r["label"], r.get("lines") or 0, r["run"], r["t_ms"])):
    raw[(r["label"], r.get("lines"))].append(
        f"| {r['run']} | {r['t_ms']} | {r['lag_ms']} | {r['plugins']} | "
        f"{'y' if r.get('gitsigns_attached') else 'n'} | "
        f"{'y' if r.get('gitsigns_loaded') else 'n'} | "
        f"{r.get('lsp_clients')} | {'y' if r.get('ts_parser') else 'n'} |")
with open(path + ".rawmd", "w") as f:
    for (lab, size), lines in sorted(raw.items(), key=lambda kv: (kv[0][1] or 0, kv[0][0])):
        f.write(f"\n#### {lab} — {size} lines\n\n")
        f.write("| run | t_ms | lag_ms | plugins | gs_attached | gs_loaded | lsp_clients | ts_parser |\n")
        f.write("|---:|---:|---:|---:|:--:|:--:|---:|:--:|\n")
        f.write("\n".join(lines) + "\n")
print(f"\nraw tables -> {path}.rawmd")
PY
