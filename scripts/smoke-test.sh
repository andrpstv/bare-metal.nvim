#!/usr/bin/env bash
# =============================================================================
# distro config smoke test
# =============================================================================
# WHAT   Automates the manual sanity checks that were run by hand on commit
#        4513f1b, so a reviewer can tell in one command whether a change broke
#        the config.
# HOW
#   ./scripts/smoke-test.sh          run all checks (startup benchmark included)
#   ./scripts/smoke-test.sh --quick  skip the startup benchmark (check 6)
#   ./scripts/smoke-test.sh -h       this help
#   SMOKE_FORCE_FAIL=3 ./scripts/smoke-test.sh
#                                    self-test: force check 3 to FAIL and prove
#                                    the suite really returns a non-zero exit
#
# EXIT   0  all executed checks passed
#        1  at least one executed check failed (summary is printed before exit)
#        2  the harness itself could not run (no nvim, no usable clock)
#
# NOTES  * bash + set -euo pipefail, portable to macOS and Linux: no GNU-only
#         flags (no `date +%s%N`, no `timeout`, no `sed -i`, no `grep -P`).
#       * No network access, no package installs, no secrets, no git writes.
#       * stylua and luacheck are NOT installed locally and are never invoked;
#         run them by hand (`stylua --check lua init.lua`) before committing.
#       * A failing check caused by a broken CONFIG is reported, not hidden.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------- options ----
QUICK=0
for arg in "$@"; do
	case "$arg" in
	--quick) QUICK=1 ;;
	-h | --help)
		# print the header block: from line 3 until the closing '# ====' rule
		# (the first rule is the opening banner, the second one closes the block)
		awk 'NR >= 3 { if ($0 ~ /^# ={4,}$/) { rules++; if (rules == 2) exit } sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
		exit 0
		;;
	*)
		echo "unknown argument: $arg (try --quick)" >&2
		exit 2
		;;
	esac
done

# ----------------------------------------------------------------- output ----
if [ -t 1 ]; then
	C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_OFF=$'\033[0m'
else
	C_RED=''; C_GRN=''; C_YLW=''; C_OFF=''
fi

PASSED=0
FAILED=0
SKIPPED=0
declare -a SUMMARY=()
CHECK_NO=""
FORCE_FAIL="${SMOKE_FORCE_FAIL:-}"

record() { # record <STATUS> <name> <note>
	# self-test hook: proves the suite can fail without editing this file
	if [ -n "$FORCE_FAIL" ] && [ "$CHECK_NO" = "$FORCE_FAIL" ]; then
		set -- "FAIL" "check $CHECK_NO forced to fail (SMOKE_FORCE_FAIL=$FORCE_FAIL)" "self-test, not a real defect"
	fi
	SUMMARY+=("$1|$2|${3:-}")
	case "$1" in
	PASS) PASSED=$((PASSED + 1)); printf '  %sPASS%s  %s\n' "$C_GRN" "$C_OFF" "$2" ;;
	FAIL) FAILED=$((FAILED + 1)); printf '  %sFAIL%s  %s\n' "$C_RED" "$C_OFF" "$2" ;;
	SKIP) SKIPPED=$((SKIPPED + 1)); printf '  %sSKIP%s  %s\n' "$C_YLW" "$C_OFF" "$2" ;;
	esac
	if [ -n "${3:-}" ]; then
		printf '        %s\n' "$3"
	fi
}

section() { # section "<n>. <title>"  (also selects the self-test target)
	CHECK_NO="${1%%.*}"
	printf '\n== %s ==\n' "$1"
}

# ------------------------------------------------------------------ clock ----
# millisecond wall clock, portable: python3 -> perl -> no benchmark possible
if command -v python3 >/dev/null 2>&1; then
	now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
elif command -v perl >/dev/null 2>&1; then
	now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }
else
	now_ms() { return 1; }
fi

TMPDIR_SMOKE="$(mktemp -d "${TMPDIR:-/tmp}/distro-smoke.XXXXXX")"
cleanup() { rm -rf "$TMPDIR_SMOKE"; }
trap cleanup EXIT

printf 'distro smoke test — repo: %s\n' "$REPO_ROOT"
printf 'nvim: %s\n' "$(nvim --version 2>/dev/null | head -1 || echo 'NOT FOUND')"

if ! command -v nvim >/dev/null 2>&1; then
	printf '\n%sFAIL%s  nvim not found in PATH\n' "$C_RED" "$C_OFF"
	exit 2
fi

# =============================================================== check 1 =====
# Config loads and prints nothing on stderr. Any output is a failure.
section "1. config loads cleanly"
ERR_FILE="$TMPDIR_SMOKE/stderr.txt"
if nvim --headless -c 'qa!' >/dev/null 2>"$ERR_FILE"; then
	STDERR_OUT="$(cat "$ERR_FILE")"
	if [ -z "$STDERR_OUT" ]; then
		record PASS "nvim --headless -c 'qa!' exits 0 with empty stderr"
	else
		record FAIL "nvim --headless -c 'qa!' exits 0 with empty stderr" "stderr: ${STDERR_OUT}"
	fi
else
	record FAIL "nvim --headless -c 'qa!' exits 0 with empty stderr" "non-zero exit: $(cat "$ERR_FILE")"
fi

# =============================================================== check 2 =====
# Bootstrap version guard. Two independent assertions, both spelled out in the
# verdict line so the result cannot be mistaken for something else:
#   (a) the version banner from `nvim --version` is >= REQUIRED, compared
#       numerically in awk (no string compare, no locale games);
#   (b) the running nvim itself answers vim.fn.has("nvim-REQUIRED") == 1, read
#       back from a file that the nvim process writes. `:lua print` goes to
#       stderr under --headless and emits no trailing newline, so scraping its
#       output is not a sound way to assert anything -- that bug made this
#       check report a false FAIL on a healthy 0.11.4.
# Plus a static check: the guard is still present in the source.
section "2. bootstrap version guard (>= 0.11)"
NVIM_VER="$(nvim --version | head -1 | sed -n 's/^NVIM v\([0-9][0-9.]*\).*/\1/p')"
REQUIRED="0.11"
HAS_FILE="$TMPDIR_SMOKE/has.txt"
if [ -z "$NVIM_VER" ]; then
	record FAIL "running nvim satisfies required >= $REQUIRED" "could not parse version banner: '$(nvim --version | head -1)'"
else
	nvim --headless -c "lua local f=io.open('$HAS_FILE','w'); f:write(tostring(vim.fn.has('nvim-$REQUIRED'))); f:close()" -c 'qa!' >/dev/null 2>&1 || true
	HAS_VAL="$(cat "$HAS_FILE" 2>/dev/null || printf '0')"
	VER_GE="$(awk -v a="$NVIM_VER" -v b="$REQUIRED" 'BEGIN{
		na=split(a,x,"."); nb=split(b,y,".");
		for (i=1;i<=3;i++) {
			va=(i<=na?x[i]+0:0); vb=(i<=nb?y[i]+0:0);
			if (va>vb) { print "yes"; exit }
			if (va<vb) { print "no";  exit }
		}
		print "yes";
	}')"
	if [ "$VER_GE" = "yes" ] && [ "$HAS_VAL" = "1" ]; then
		record PASS "running nvim $NVIM_VER >= required $REQUIRED (banner compare=$VER_GE, vim.fn.has(\"nvim-$REQUIRED\")=$HAS_VAL reported by nvim itself)"
	else
		record FAIL "running nvim $NVIM_VER >= required $REQUIRED" "banner compare=$VER_GE, vim.fn.has(\"nvim-$REQUIRED\")=$HAS_VAL"
	fi
fi
GUARD_FILE=""
for candidate in init.lua lua/core/health.lua; do
	if [ -f "$candidate" ] && grep -q "nvim-$REQUIRED" "$candidate"; then
		GUARD_FILE="$candidate"
		break
	fi
done
if [ -n "$GUARD_FILE" ]; then
	record PASS "version guard present in $GUARD_FILE"
else
	record FAIL "version guard present" "no file mentions nvim-$REQUIRED (checked init.lua, lua/core/health.lua)"
fi

# =============================================================== check 3 =====
# The 9 new modules must require cleanly; print the error text on failure.
section "3. new modules require cleanly"
MODULES="core.turbo core.weak_hw core.term_guard core.git_colors distro.trace distro.tracehooks distro.traceui distro.bench distro.benchui"
MOD_OUT="$(nvim --headless \
	-c "lua local ms={'${MODULES// /','}'}; for _,m in ipairs(ms) do local ok,e=pcall(require,m); print((ok and 'OK ' or 'FAIL ')..m..(ok and '' or (' '..tostring(e)))) end" \
	-c 'qa!' 2>&1 | tr -d '\r' || true)"
MOD_BAD="$(printf '%s\n' "$MOD_OUT" | grep '^FAIL' || true)"
MOD_COUNT="$(printf '%s\n' "$MOD_OUT" | grep -c '^OK' || true)"
if [ "$MOD_COUNT" -eq 9 ] && [ -z "$MOD_BAD" ]; then
	record PASS "9/9 modules require without error"
else
	record FAIL "9/9 modules require without error" "$(printf '%s' "$MOD_BAD" | tr '\n' ' ')"
fi

# =============================================================== check 4 =====
# Every user command named below exists. CMD_COUNT is derived from the list
# itself, so the section header, the pass line and the assertion can never
# disagree about how many commands there are.
#   nvim_get_commands({builtin=false}) returns {} in --headless: the user
#   commands of this config live in files that lazy.nvim (or the augroup that
#   loads them) only evaluates in a real UI, so the API sees an empty table.
#   Two working methods: grep the source for nvim_create_user_command (source
#   of truth, static) and vim.fn.exists(":Cmd") == 2 (runtime, works in headless
#   for everything already loaded).
COMMANDS="ConfigHealth Distro DistroBench DistroBenchUI DistroBinaries DistroCheck DistroClean DistroDiag DistroInstall DistroMirror DistroParsers DistroTools DistroTrace DistroUpdate Format FormatterToggleFt FormatToggle PairsStatus TreesitterTier TurboOff TurboOn TurboStatus WeakHwOff WeakHwOn WeakHwStatus"
CMD_COUNT="$(printf '%s\n' $COMMANDS | wc -l | tr -d ' ')"
section "4. user commands exist ($CMD_COUNT names)"
STATIC_MISSING=""
for cmd in $COMMANDS; do
	if ! grep -rqs "nvim_create_user_command(\"$cmd\"" lua init.lua; then
		STATIC_MISSING="$STATIC_MISSING $cmd"
	fi
done
if [ -z "$STATIC_MISSING" ]; then
	record PASS "static: all $CMD_COUNT commands declared in source"
else
	record FAIL "static: commands declared in source" "missing:$STATIC_MISSING"
fi

EXISTS_OUT="$(nvim --headless \
	-c "lua local cs={'$(printf '%s' "$COMMANDS" | tr ' ' '\n' | sed "s/.*/'&'/" | tr '\n' ',' | sed 's/,$//')'}; for _,c in ipairs(cs) do if vim.fn.exists(':'..c)~=2 then print('MISSING '..c) end end" \
	-c 'qa!' 2>&1 | tr -d '\r' | grep '^MISSING ' || true)"
LAZY_OK=""
HARD_MISSING=""
for line in $EXISTS_OUT; do
	cmd="${line#MISSING }"
	if grep -rqs "nvim_create_user_command(\"$cmd\"" lua/modules/ 2>/dev/null; then
		LAZY_OK="$LAZY_OK $cmd"
	else
		HARD_MISSING="$HARD_MISSING $cmd"
	fi
done
if [ -z "$HARD_MISSING" ]; then
	if [ -n "$LAZY_OK" ]; then
		record PASS "runtime: exists(':Cmd')==2 for all eagerly loaded commands" "lazily loaded (not in exists() under --headless, expected):$LAZY_OK"
	else
		record PASS "runtime: exists(':Cmd')==2 for all commands"
	fi
else
	record FAIL "runtime: exists(':Cmd')==2" "missing:$HARD_MISSING"
fi

# =============================================================== check 5 =====
# gopls attaches to a Go buffer and reports 0 diagnostics on valid code.
# The fixture lives in a temp dir with a go.mod: without a module, gopls emits
# "go list | No packages found for open file" and the check would report a
# config problem that is really a fixture problem.
section "5. gopls attaches to valid Go, 0 diagnostics"
FIXTURE="$TMPDIR_SMOKE/gofixture"
mkdir -p "$FIXTURE"
printf 'module smoke\n\ngo 1.21\n' >"$FIXTURE/go.mod"
cat >"$FIXTURE/main.go" <<'GOEOF'
package main

import "fmt"

func main() {
	fmt.Println("hi")
}
GOEOF
if ! command -v gopls >/dev/null 2>&1; then
	record SKIP "gopls attaches to valid Go, 0 diagnostics" "gopls not in PATH (install it to run this check)"
else
	GOPLS_TIMEOUT=25
	# wrapped in a subshell with stderr discarded: the watchdog below kills a
	# background job and bash would print a "Killed: 9" job report otherwise
	{
		nvim --headless "$FIXTURE/main.go" \
		-c "lua local deadline=vim.uv.hrtime()+$GOPLS_TIMEOUT*1000000000
local function done()
  local n=#vim.lsp.get_clients({bufnr=0})
  if n==0 and vim.uv.hrtime()<deadline then return vim.defer_fn(done,250) end
  local d=vim.diagnostic.get(0)
  print('RESULT clients='..n..' diags='..#d)
  for _,x in ipairs(d) do print('DIAG '..tostring(x.source)..' '..x.message) end
  vim.cmd('qa!')
end
done()" >"$TMPDIR_SMOKE/gopls.txt" 2>&1 &
		GOPLS_PID=$!
		# poll in the foreground instead of a watchdog subshell: no second
		# background job to kill, so no "Killed: 9" job report on the console
		GOPLS_WAITED=0
		while kill -0 "$GOPLS_PID" 2>/dev/null; do
			if [ "$GOPLS_WAITED" -ge "$GOPLS_TIMEOUT" ]; then
				kill -9 "$GOPLS_PID" 2>/dev/null || true
				break
			fi
			sleep 1
			GOPLS_WAITED=$((GOPLS_WAITED + 1))
		done
		wait "$GOPLS_PID" 2>/dev/null || true
	} 2>/dev/null
	GOPLS_RESULT="$(grep '^RESULT' "$TMPDIR_SMOKE/gopls.txt" | tr -d '\r' | tail -1 || true)"
	GOPLS_DETAIL="$(grep '^DIAG' "$TMPDIR_SMOKE/gopls.txt" | tr -d '\r' || true)"
	if [ -z "$GOPLS_RESULT" ]; then
		record FAIL "gopls attaches to valid Go, 0 diagnostics" "no result within ${GOPLS_TIMEOUT}s: $(tail -2 "$TMPDIR_SMOKE/gopls.txt" | tr '\n' ' ')"
	else
		CLIENTS="$(printf '%s' "$GOPLS_RESULT" | sed -n 's/.*clients=\([0-9]*\).*/\1/p')"
		DIAGS="$(printf '%s' "$GOPLS_RESULT" | sed -n 's/.*diags=\([0-9]*\).*/\1/p')"
		if [ "${CLIENTS:-0}" -ge 1 ] && [ "${DIAGS:-1}" -eq 0 ]; then
			record PASS "gopls attached (clients=$CLIENTS) with 0 diagnostics on valid Go"
		else
			record FAIL "gopls attaches to valid Go, 0 diagnostics" "$GOPLS_RESULT | $GOPLS_DETAIL"
		fi
	fi
fi

# =============================================================== check 6 =====
# Startup sanity: median of 5 runs, ours vs `nvim --clean`; fail only if ours
# exceeds 5x clean, so ordinary variance does not fail the suite.
section "6. startup: median of 5, ours vs --clean (limit 5x)"
if [ "$QUICK" -eq 1 ]; then
	record SKIP "startup median benchmark" "--quick"
elif ! now_ms >/dev/null 2>&1; then
	record SKIP "startup median benchmark" "no millisecond clock (needs python3 or perl)"
else
	median_ms() { # median_ms <label> <runs>
		local label="$1" runs="$2" i start end
		local -a samples=()
		for i in $(seq 1 "$runs"); do
			start="$(now_ms)"
			case "$label" in
			ours) nvim --headless -c 'qa!' >/dev/null 2>&1 || true ;;
			clean) nvim --clean --headless -c 'qa!' >/dev/null 2>&1 || true ;;
			esac
			end="$(now_ms)"
			samples+=("$((end - start))")
		done
		printf '%s\n' "${samples[@]}" | sort -n | awk -v n="$runs" 'NR==int((n+1)/2){print $1; exit}'
	}
	RUNS=5
	# one warm-up pair, discarded: first run pays lazy.nvim/uv cache costs
	median_ms ours 1 >/dev/null
	median_ms clean 1 >/dev/null
	OURS_MS="$(median_ms ours "$RUNS")"
	CLEAN_MS="$(median_ms clean "$RUNS")"
	if [ "$CLEAN_MS" -le 0 ]; then CLEAN_MS=1; fi
	RATIO=$((OURS_MS / CLEAN_MS))
	NOTE="ours=${OURS_MS}ms clean=${CLEAN_MS}ms ratio=${RATIO}x (limit 5x, median of $RUNS)"
	if [ "$OURS_MS" -gt $((CLEAN_MS * 5)) ]; then
		record FAIL "startup within 5x of clean" "$NOTE"
	else
		record PASS "startup within 5x of clean" "$NOTE"
	fi
fi

# =============================================================== summary =====
printf '\n=========================================\n'
printf 'summary: %d passed, %d failed, %d skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
printf -- '-----------------------------------------\n'
for line in "${SUMMARY[@]}"; do
	printf '%-4s %s\n' "${line%%|*}" "$(printf '%s' "$line" | cut -d'|' -f2)"
done
printf -- '-----------------------------------------\n'
if [ "$FAILED" -gt 0 ]; then
	printf '%sRESULT: FAIL%s — a red line above may be a genuinely broken config.\n' "$C_RED" "$C_OFF"
	exit 1
fi
printf '%sRESULT: PASS%s\n' "$C_GRN" "$C_OFF"
exit 0
