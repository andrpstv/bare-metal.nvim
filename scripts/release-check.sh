#!/usr/bin/env bash
# =============================================================================
# release gate: privacy + smoke in one command.
#   ./scripts/release-check.sh
# WHAT   1) no personal workspace files are tracked by git
#           (AGENTS.md/SOUL.md/USER.md/IDENTITY.md/BOOTSTRAP.md/MEMORY.md/memory/
#           must stay local — .gitignore covers them, this gate proves it);
#        2) full smoke-test.sh suite passes.
# WHY    A public release of a personal config must never bundle the owner's
#        notes, and must boot clean. One command, zero excuses.
# =============================================================================
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"

LEAK="$(git -C "$REPO" ls-files | grep -Ei '^(AGENTS\.md|SOUL\.md|USER\.md|IDENTITY\.md|BOOTSTRAP\.md|MEMORY\.md|memory/)' || true)"
if [ -n "$LEAK" ]; then
	echo "FAIL: personal files tracked by git:"
	printf '%s\n' "$LEAK"
	exit 1
fi
echo "PASS: no personal files tracked"

exec "$REPO/scripts/smoke-test.sh"
