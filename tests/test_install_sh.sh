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
# 1. agents-md (project guidelines block)
# ---------------------------------------------------------------------------
BLOCK="${SOURCE}/content/guidelines-block.md"
BEGIN_MARK='<!-- BEGIN jmix-agent-toolkit -->'
END_MARK='<!-- END jmix-agent-toolkit -->'

# 1a. No guidelines file yet -> the file is created holding exactly the block.
bash "$INSTALL" agents-md --agents claude,codex,opencode,junie --source "$SOURCE" >/dev/null
[ -f "${PROJECT}/CLAUDE.md" ]            || fail "agents-md: CLAUDE.md missing"
[ -f "${PROJECT}/AGENTS.md" ]            || fail "agents-md: AGENTS.md missing"
[ -f "${PROJECT}/.junie/guidelines.md" ] || fail "agents-md: .junie/guidelines.md missing"
cmp -s "${PROJECT}/CLAUDE.md" "$BLOCK"   || fail "agents-md: fresh CLAUDE.md is not exactly the block"
pass "agents-md creates a guidelines file holding exactly the block"

# 1b. An up-to-date file is left completely alone: no rewrite, no backup (issue #22).
sleep 1
touch "${PROJECT}/.mtime-ref"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
[ ! -e "${PROJECT}/CLAUDE.md.bak" ] || fail "agents-md: unchanged file was backed up"
[ ! "${PROJECT}/CLAUDE.md" -nt "${PROJECT}/.mtime-ref" ] || fail "agents-md: unchanged file was rewritten"
rm -f "${PROJECT}/.mtime-ref"
pass "agents-md leaves an up-to-date block untouched"

# 1c. An old full AGENTS.md from a previous toolkit version is replaced whole,
#     with a backup. Heading "# Agent Instructions", and ONLY the
#     "## Skill routing" half of the content rule.
rm -f "${PROJECT}/CLAUDE.md"
printf '# Agent Instructions\n\nUse these instructions.\n\n## Skill routing\n\n- Persistent entity: create an entity\n' \
    > "${PROJECT}/CLAUDE.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
cmp -s "${PROJECT}/CLAUDE.md" "$BLOCK" || fail "agents-md: legacy guidelines not replaced by the block"
grep -q '^# Agent Instructions' "${PROJECT}/CLAUDE.md.bak" || fail "agents-md: legacy guidelines not backed up"
pass "agents-md replaces a legacy file (Agent Instructions + Skill routing)"

# 1c2. The other legacy heading and ONLY the other half of the content rule:
#      "# Coding Guidelines" (this toolkit's first heading) + a jmix skill name.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak*
printf '# Coding Guidelines\n\nRead jmix-create-entity before adding an entity.\n' \
    > "${PROJECT}/CLAUDE.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
cmp -s "${PROJECT}/CLAUDE.md" "$BLOCK" \
    || fail "agents-md: legacy Coding Guidelines file not replaced by the block"
grep -q '^# Coding Guidelines' "${PROJECT}/CLAUDE.md.bak" \
    || fail "agents-md: legacy Coding Guidelines not backed up"
pass "agents-md replaces a legacy file (Coding Guidelines + skill name)"

# 1c3. A developer file with a legacy-looking heading but no toolkit content is
#      NOT legacy: it must be appended to, never replaced.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak*
printf '# Agent Instructions\n\nAlways rebase before pushing.\n' > "${PROJECT}/CLAUDE.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
grep -q 'Always rebase before pushing.' "${PROJECT}/CLAUDE.md" \
    || fail "agents-md: a non-toolkit file with a legacy heading was wrongly replaced"
grep -qF "$BEGIN_MARK" "${PROJECT}/CLAUDE.md" || fail "agents-md: block not appended to non-toolkit file"
pass "agents-md does not treat a lookalike heading alone as a legacy file"

# 1d. The developer's own file is kept and the block is appended below it.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak*
printf '# My project\n\nRun the linter before every commit.\n' > "${PROJECT}/CLAUDE.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
grep -q 'Run the linter before every commit.' "${PROJECT}/CLAUDE.md" \
    || fail "agents-md: developer content lost on append"
grep -qF "$BEGIN_MARK" "${PROJECT}/CLAUDE.md" || fail "agents-md: block not appended"
[ -f "${PROJECT}/CLAUDE.md.bak" ] || fail "agents-md: appended-to file not backed up"
pass "agents-md appends the block and keeps the developer's own content"

# 1d2. A 0-byte destination file is a degenerate "anything else" case: appended
# to with exactly one blank-line separator, never an extra leading blank line.
# Regression guard for a byte-for-byte divergence in install.ps1, where an
# empty file wrongly grew an extra blank line before the block.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak*
printf '' > "${PROJECT}/CLAUDE.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
{ printf '\n'; cat "$BLOCK"; } > "${WORK}/expected-1d2"
cmp -s "${PROJECT}/CLAUDE.md" "${WORK}/expected-1d2" \
    || fail "agents-md: empty destination file not appended to byte-for-byte"
[ -f "${PROJECT}/CLAUDE.md.bak" ] || fail "agents-md: empty destination file not backed up"
pass "agents-md appends to an empty destination file with exactly one blank-line separator"

# Restore the state handed to case 1e: developer content + appended block, one
# backup, so 1e's assumptions about backup filenames still hold.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak*
printf '# My project\n\nRun the linter before every commit.\n' > "${PROJECT}/CLAUDE.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null

# 1e. Appending is idempotent: a second run replaces the region in place.
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
[ "$(grep -cF "$BEGIN_MARK" "${PROJECT}/CLAUDE.md")" -eq 1 ] \
    || fail "agents-md: block appended twice on re-run"
grep -q 'Run the linter before every commit.' "${PROJECT}/CLAUDE.md" \
    || fail "agents-md: developer content lost on re-run"
[ ! -e "${PROJECT}/CLAUDE.md.bak1" ] \
    || fail "agents-md: up-to-date block inside a developer file made a new backup"
pass "agents-md does not append the block twice"

# 1f. Only the marked region is replaced; text above AND below survives, and no
#     backup is made because nothing outside our own region changed.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak*
{
    printf 'ABOVE-SENTINEL\n\n'
    printf '%s\n' "$BEGIN_MARK"
    printf 'stale block content\n'
    printf '%s\n' "$END_MARK"
    printf '\nBELOW-SENTINEL\n'
} > "${PROJECT}/CLAUDE.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
grep -q 'ABOVE-SENTINEL' "${PROJECT}/CLAUDE.md" || fail "agents-md: text above the block lost"
grep -q 'BELOW-SENTINEL' "${PROJECT}/CLAUDE.md" || fail "agents-md: text below the block lost"
if grep -q 'stale block content' "${PROJECT}/CLAUDE.md"; then
    fail "agents-md: stale block content kept"
fi
[ ! -e "${PROJECT}/CLAUDE.md.bak" ] || fail "agents-md: in-place block replacement made a backup"
pass "agents-md replaces only the marked region"

# 1g. A half-written marker is malformed: append, never truncate.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak*
printf 'KEEP-ME\n%s\nhalf a block\n' "$BEGIN_MARK" > "${PROJECT}/CLAUDE.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
grep -q 'KEEP-ME' "${PROJECT}/CLAUDE.md"      || fail "agents-md: malformed-marker file truncated"
grep -q 'half a block' "${PROJECT}/CLAUDE.md" || fail "agents-md: malformed-marker content lost"
grep -qF "$END_MARK" "${PROJECT}/CLAUDE.md"   || fail "agents-md: block not appended to malformed file"
pass "agents-md appends to a half-marked file instead of truncating it"

# 1h. A legacy full-file replaced correctly even with CRLF line endings, so
#     install.sh's byte-exact marker/heading comparisons are not fooled by a
#     trailing \r on every line.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak*
printf '# Agent Instructions\r\n\r\nUse these instructions.\r\n\r\n## Skill routing\r\n\r\n- Persistent entity: create an entity\r\n' \
    > "${PROJECT}/CLAUDE.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
cmp -s "${PROJECT}/CLAUDE.md" "$BLOCK" || fail "agents-md: CRLF legacy guidelines not replaced by the block"
grep -q 'Agent Instructions' "${PROJECT}/CLAUDE.md.bak" || fail "agents-md: CRLF legacy guidelines not backed up"
pass "agents-md replaces a legacy file with CRLF line endings"

# 1i. A legacy file with a leading UTF-8 BOM is still recognised.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak*
printf '\xef\xbb\xbf# Coding Guidelines\n\nRead jmix-create-entity before adding an entity.\n' \
    > "${PROJECT}/CLAUDE.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
cmp -s "${PROJECT}/CLAUDE.md" "$BLOCK" || fail "agents-md: BOM legacy guidelines not replaced by the block"
grep -q 'Coding Guidelines' "${PROJECT}/CLAUDE.md.bak" || fail "agents-md: BOM legacy guidelines not backed up"
pass "agents-md replaces a legacy file with a leading UTF-8 BOM"

# 1j. A developer file already holding the block, whole file CRLF: only the
#     marked region is replaced in place, no backup, and CRLF outside the
#     region survives untouched.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak*
{
    printf 'ABOVE-SENTINEL\r\n\r\n'
    printf '%s\r\n' "$BEGIN_MARK"
    printf 'stale block content\r\n'
    printf '%s\r\n' "$END_MARK"
    printf '\r\nBELOW-SENTINEL\r\n'
} > "${PROJECT}/CLAUDE.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
grep -qF "$(printf 'ABOVE-SENTINEL\r')" "${PROJECT}/CLAUDE.md" \
    || fail "agents-md(CRLF): text above the block lost its CRLF ending"
grep -qF "$(printf 'BELOW-SENTINEL\r')" "${PROJECT}/CLAUDE.md" \
    || fail "agents-md(CRLF): text below the block lost its CRLF ending"
if grep -q 'stale block content' "${PROJECT}/CLAUDE.md"; then
    fail "agents-md(CRLF): stale block content kept"
fi
[ ! -e "${PROJECT}/CLAUDE.md.bak" ] || fail "agents-md(CRLF): in-place block replacement made a backup"
pass "agents-md replaces only the marked region in a CRLF file, preserving CRLF outside it"

# 1k. A third heading this toolkit actually shipped: "# Jmix Coding Guidelines".
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak*
printf '# Jmix Coding Guidelines\n\nUse these instructions.\n\n## Skill routing\n\n- Persistent entity: create an entity\n' \
    > "${PROJECT}/CLAUDE.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
cmp -s "${PROJECT}/CLAUDE.md" "$BLOCK" \
    || fail "agents-md: '# Jmix Coding Guidelines' legacy file not replaced by the block"
grep -q 'Jmix Coding Guidelines' "${PROJECT}/CLAUDE.md.bak" \
    || fail "agents-md: '# Jmix Coding Guidelines' legacy file not backed up"
pass "agents-md replaces a legacy '# Jmix Coding Guidelines' file"

# 1l. An early-vintage file: no "## Skill routing" heading at all, its only
#     toolkit signal is an old skill name ("jmix-services") that predates
#     jmix-create-entity.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak*
printf '# Coding Guidelines\n\nSee jmix-services for the service layer conventions.\n' \
    > "${PROJECT}/CLAUDE.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
cmp -s "${PROJECT}/CLAUDE.md" "$BLOCK" \
    || fail "agents-md: early-vintage file (jmix-services, no Skill routing) not replaced"
grep -q 'jmix-services' "${PROJECT}/CLAUDE.md.bak" \
    || fail "agents-md: early-vintage file not backed up"
pass "agents-md replaces an early-vintage file naming only an old jmix-* skill"

# 1m. A no-trailing-newline destination file is appended to exactly like one
#     that already ends in a newline (guard, not a fix -- already byte-identical
#     across installers).
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak*
printf '# My project\n\nRun the linter before every commit.' > "${PROJECT}/CLAUDE.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
{ printf '# My project\n\nRun the linter before every commit.\n\n'; cat "$BLOCK"; } > "${WORK}/expected-1m"
cmp -s "${PROJECT}/CLAUDE.md" "${WORK}/expected-1m" \
    || fail "agents-md: no-trailing-newline destination not appended to byte-for-byte"
[ -f "${PROJECT}/CLAUDE.md.bak" ] || fail "agents-md: no-trailing-newline destination not backed up"
pass "agents-md appends to a no-trailing-newline destination with exactly one blank-line separator"

# Reset so later sections start from a clean project guidelines state.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak*

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
[ -d "${HOME}/.agents/.jmix/skills/v3" ]                  || fail "skills(global): v3 store missing"
[ -e "${HOME}/.claude/skills/${SKILL}/SKILL.md" ]         || fail "skills(global): symlink does not resolve"
pass "skills(global) builds v3 store under HOME and resolving symlink"

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
