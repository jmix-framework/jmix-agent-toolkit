#!/usr/bin/env bash
# Functional tests for install.sh.
#
# Runs the installer's subcommands against a local checkout (via --source) into
# an isolated temp HOME and project dir, then asserts the produced files and
# symlinks. No network and no external agent CLIs required.
#
# Usage: tests/test_install_sh.sh [SOURCE_DIR]
#   SOURCE_DIR defaults to the repository root (parent of this script's dir).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SOURCE="${1:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"
INSTALL="${SOURCE}/install.sh"
SKILL="jmix-create-entity"   # a stable skill folder name used for symlink checks

[ -f "$INSTALL" ] || { echo "FAIL: install.sh not found at ${INSTALL}"; exit 1; }

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t jmix-itest)"
trap 'rm -rf "$WORK"' EXIT

# Isolate the global scope: install.sh writes global skills under $HOME.
export HOME="${WORK}/home"
PROJECT="${WORK}/project"
mkdir -p "$HOME" "$PROJECT"
cd "$PROJECT"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# ---------------------------------------------------------------------------
# 1. agents-md (project guidelines)
# ---------------------------------------------------------------------------
bash "$INSTALL" agents-md --agents claude,codex,opencode,junie --source "$SOURCE" >/dev/null
[ -f "${PROJECT}/CLAUDE.md" ]            || fail "agents-md: CLAUDE.md missing"
[ -f "${PROJECT}/AGENTS.md" ]            || fail "agents-md: AGENTS.md missing"
[ -f "${PROJECT}/.junie/guidelines.md" ] || fail "agents-md: .junie/guidelines.md missing"
cmp -s "${PROJECT}/CLAUDE.md" "${SOURCE}/content/AGENTS.md" || fail "agents-md: CLAUDE.md content mismatch"
pass "agents-md installs guidelines for all agents"

# Guidelines are always backed up on overwrite (no --backup-existing-files),
# and repeated runs dedup the backup name: .bak, then .bak1 (issue #17).
printf 'sentinel-1' > "${PROJECT}/CLAUDE.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
[ -f "${PROJECT}/CLAUDE.md.bak" ] || fail "agents-md: existing CLAUDE.md not backed up without flag"
[ "$(cat "${PROJECT}/CLAUDE.md.bak")" = "sentinel-1" ] || fail "agents-md: backup .bak lost original content"
cmp -s "${PROJECT}/CLAUDE.md" "${SOURCE}/content/AGENTS.md" || fail "agents-md: reinstalled CLAUDE.md content mismatch"

printf 'sentinel-2' > "${PROJECT}/CLAUDE.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
[ -f "${PROJECT}/CLAUDE.md.bak1" ] || fail "agents-md: second backup not deduped to .bak1"
[ "$(cat "${PROJECT}/CLAUDE.md.bak")" = "sentinel-1" ] || fail "agents-md: dedup overwrote earlier .bak backup"
[ "$(cat "${PROJECT}/CLAUDE.md.bak1")" = "sentinel-2" ] || fail "agents-md: .bak1 has wrong content"
pass "agents-md always backs up guidelines with deduped .bak/.bak1 names"

# ---------------------------------------------------------------------------
# 2. skills, local scope (per-skill symlinks into agent dirs)
# ---------------------------------------------------------------------------
bash "$INSTALL" skills --agents claude,codex,opencode,junie --scope local --source "$SOURCE" >/dev/null
[ -d "${PROJECT}/.skills" ] || fail "skills(local): .skills store missing"
find "${PROJECT}/.skills" -maxdepth 1 -mindepth 1 -name 'jmix-*' -type d | grep -q . \
    || fail "skills(local): store has no jmix-* folders"
for rel in ".claude/skills" ".agents/skills" ".junie/skills"; do
    [ -e "${PROJECT}/${rel}/${SKILL}/SKILL.md" ] \
        || fail "skills(local): ${rel}/${SKILL} does not resolve"
done
pass "skills(local) builds store and resolving symlinks for all agents"

for rel in ".claude/skills" ".agents/skills" ".junie/skills"; do
    tgt="$(readlink "${PROJECT}/${rel}/${SKILL}")"
    case "$tgt" in
        /*) fail "skills(local): ${rel}/${SKILL} target is absolute (${tgt}); must be relative" ;;
    esac
done
pass "skills(local) symlink targets are relative (portable across clones)"

# ---------------------------------------------------------------------------
# 3. skills, global scope (under $HOME) -- store keyed by the branch (CONTENT_REF)
# ---------------------------------------------------------------------------
bash "$INSTALL" skills --agents claude --scope global --source "$SOURCE" >/dev/null
[ -d "${HOME}/.agents/.jmix/skills/v2" ]                  || fail "skills(global): v2 store missing"
[ -e "${HOME}/.claude/skills/${SKILL}/SKILL.md" ]         || fail "skills(global): symlink does not resolve"
pass "skills(global) builds v2 store under HOME and resolving symlink"

# ---------------------------------------------------------------------------
# 5. OpenCode MCP entries (no agent CLI needed; requires jq)
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
    cfg="${HOME}/.config/opencode/opencode.json"
    bash "$INSTALL" mcp-jetbrains --agents opencode >/dev/null
    jq -e '.mcp.jetbrains.url == "http://localhost:64342/sse"' "$cfg" >/dev/null \
        || fail "mcp-jetbrains: opencode jetbrains entry missing/wrong"
    # Re-running an already-configured step must stay idempotent (exit 0) -- the
    # same guarantee the Claude path gets from its remove-then-add helper.
    bash "$INSTALL" mcp-jetbrains --agents opencode >/dev/null \
        || fail "mcp-jetbrains: re-run not idempotent (non-zero exit)"
    bash "$INSTALL" mcp-context7 --agents opencode --context7-key TESTKEY >/dev/null
    jq -e '.mcp.context7.command | index("TESTKEY")' "$cfg" >/dev/null \
        || fail "mcp-context7: opencode context7 key not written"
    pass "opencode MCP entries (jetbrains + context7) written to opencode.json"
else
    echo "skip: jq not found, skipping OpenCode MCP assertions"
fi

# ---------------------------------------------------------------------------
# 6. Negative cases
# ---------------------------------------------------------------------------
if bash "$INSTALL" agents-md --source "$SOURCE" >/dev/null 2>&1; then
    fail "negative: agents-md without --agents should fail"
fi
pass "agents-md without --agents fails as expected"

if bash "$INSTALL" skills --agents bogus --scope local --source "$SOURCE" >/dev/null 2>&1; then
    fail "negative: unknown agent should fail"
fi
pass "unknown agent fails as expected"

if bash "$INSTALL" agents-md --agents claude --source "${WORK}/does-not-exist" >/dev/null 2>&1; then
    fail "negative: missing --source dir should fail"
fi
pass "missing --source directory fails as expected"

echo ""
echo "ALL BASH INSTALLER TESTS PASSED"
