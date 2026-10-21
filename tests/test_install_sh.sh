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
unset CODEX_HOME XDG_CONFIG_HOME JUNIE_HOME
# Nothing listens on port 9: the IDE MCP server probe sees no IDE.
export JMIX_IDE_MCP_PORT=9
PROJECT="${WORK}/project"
mkdir -p "$HOME" "$PROJECT"
cd "$PROJECT"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

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
cmp -s "${PROJECT}/CLAUDE.md" "$BLOCK"   || fail "agents-md: fresh CLAUDE.md is not exactly the block"
cmp -s "${PROJECT}/AGENTS.md" "$BLOCK"   || fail "agents-md: AGENTS.md shared by codex/opencode/junie is not exactly the block"
# Junie reads AGENTS.md; the deprecated .junie/guidelines.md is not created.
[ ! -e "${PROJECT}/.junie/guidelines.md" ] || fail "agents-md: Junie got a .junie/guidelines.md it would not read"
pass "agents-md creates a guidelines file holding exactly the block"

# 1a2. --conventions names the files instead of the agents: agents (AGENTS.md)
#      and claude (CLAUDE.md); an unknown one is refused.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}/AGENTS.md"
bash "$INSTALL" agents-md --conventions agents --source "$SOURCE" >/dev/null
[ -f "${PROJECT}/AGENTS.md" ] && [ ! -e "${PROJECT}/CLAUDE.md" ] || fail "agents-md: --conventions agents did not write AGENTS.md alone"
bash "$INSTALL" agents-md --conventions claude,agents --source "$SOURCE" >/dev/null
cmp -s "${PROJECT}/CLAUDE.md" "$BLOCK" && cmp -s "${PROJECT}/AGENTS.md" "$BLOCK" || fail "agents-md: --conventions claude,agents wrong"
# Values are case-insensitive, as in install.ps1, the agent names too.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}/AGENTS.md"
bash "$INSTALL" agents-md --conventions Claude,AGENTS --source "$SOURCE" >/dev/null
cmp -s "${PROJECT}/CLAUDE.md" "$BLOCK" && cmp -s "${PROJECT}/AGENTS.md" "$BLOCK" || fail "agents-md: --conventions should be case-insensitive"
bash "$INSTALL" agents-md --agents Codex --source "$SOURCE" >/dev/null || fail "agents-md: --agents Codex should mean agents"
if bash "$INSTALL" agents-md --conventions cursor --source "$SOURCE" >/dev/null 2>&1; then
    fail "agents-md: an unknown convention should fail"
fi
pass "agents-md takes --conventions agents,claude"

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
chmod 664 "${PROJECT}/CLAUDE.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
grep -q 'ABOVE-SENTINEL' "${PROJECT}/CLAUDE.md" || fail "agents-md: text above the block lost"
grep -q 'BELOW-SENTINEL' "${PROJECT}/CLAUDE.md" || fail "agents-md: text below the block lost"
if grep -q 'stale block content' "${PROJECT}/CLAUDE.md"; then
    fail "agents-md: stale block content kept"
fi
[ ! -e "${PROJECT}/CLAUDE.md.bak" ] || fail "agents-md: in-place block replacement made a backup"
[ "$(file_mode "${PROJECT}/CLAUDE.md")" = 664 ] \
    || fail "agents-md: in-place block replacement changed file permissions"
pass "agents-md replaces only the marked region"

# 1g. A half-written marker is malformed: append, never truncate.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak*
printf 'KEEP-ME\n%s\nhalf a block\n' "$BEGIN_MARK" > "${PROJECT}/CLAUDE.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
grep -q 'KEEP-ME' "${PROJECT}/CLAUDE.md"      || fail "agents-md: malformed-marker file truncated"
grep -q 'half a block' "${PROJECT}/CLAUDE.md" || fail "agents-md: malformed-marker content lost"
grep -qF "$END_MARK" "${PROJECT}/CLAUDE.md"   || fail "agents-md: block not appended to malformed file"
pass "agents-md appends to a half-marked file instead of truncating it"

# A later run must pair the appended block with its own nearest BEGIN marker;
# the original orphan marker and the developer's content remain unmanaged.
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
grep -q 'KEEP-ME' "${PROJECT}/CLAUDE.md"      || fail "agents-md: malformed-marker file truncated on re-run"
grep -q 'half a block' "${PROJECT}/CLAUDE.md" || fail "agents-md: malformed-marker content lost on re-run"
pass "agents-md preserves a half-marked prefix on re-run"

# 1g2. A marker shown as a standalone line in a fenced example above the real
#      block is not paired with the real END marker.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak*
{
    printf '# Project\n\n%smarkdown\n%s\n%s\n\n' '```' "$BEGIN_MARK" '```'
    printf 'TEAM-RULE-SENTINEL\n\n%s\nstale block\n%s\n' "$BEGIN_MARK" "$END_MARK"
} > "${PROJECT}/CLAUDE.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
grep -q 'TEAM-RULE-SENTINEL' "${PROJECT}/CLAUDE.md" \
    || fail "agents-md: text after a fenced BEGIN marker lost"
grep -q '^```$' "${PROJECT}/CLAUDE.md" \
    || fail "agents-md: fenced marker example was truncated"
pass "agents-md pairs END with the nearest owned BEGIN"

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

# 1n. A CLAUDE.md that @-imports AGENTS.md (Claude Code import syntax) is left
#     alone when AGENTS.md carries the block: Claude sees it through the import,
#     a second copy would only duplicate it. No rewrite, no backup -- and the
#     AGENTS.md agents are processed first even though claude is listed first.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak* "${PROJECT}/AGENTS.md" "${PROJECT}"/AGENTS.md.bak*
printf '# Team rules\n\nSee @AGENTS.md for the shared instructions.\n' > "${PROJECT}/CLAUDE.md"
cp "${PROJECT}/CLAUDE.md" "${WORK}/claude-import-orig"
printf '# Shared\n\nNever push to main.\n' > "${PROJECT}/AGENTS.md"
bash "$INSTALL" agents-md --agents claude,codex --source "$SOURCE" >/dev/null
grep -qF "$BEGIN_MARK" "${PROJECT}/AGENTS.md" || fail "agents-md: block not merged into AGENTS.md"
grep -q 'Never push to main.' "${PROJECT}/AGENTS.md" || fail "agents-md: AGENTS.md content lost"
cmp -s "${PROJECT}/CLAUDE.md" "${WORK}/claude-import-orig" \
    || fail "agents-md: CLAUDE.md that imports AGENTS.md was rewritten"
[ ! -e "${PROJECT}/CLAUDE.md.bak" ] || fail "agents-md: CLAUDE.md that imports AGENTS.md was backed up"
pass "agents-md skips a CLAUDE.md that imports an AGENTS.md carrying the block"

# 1n2. Same import, only claude selected later: AGENTS.md still carries the block
#      from the earlier run, so CLAUDE.md is still skipped.
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
cmp -s "${PROJECT}/CLAUDE.md" "${WORK}/claude-import-orig" \
    || fail "agents-md: importing CLAUDE.md rewritten although AGENTS.md already carries the block"
pass "agents-md keeps skipping an importing CLAUDE.md on a claude-only re-run"

# 1o. Same import, but AGENTS.md has no block and only claude is selected: nothing
#     else routes Claude to the skills, so the block goes into CLAUDE.md and
#     AGENTS.md is not touched.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak* "${PROJECT}/AGENTS.md" "${PROJECT}"/AGENTS.md.bak*
printf '# Team rules\n\nSee @AGENTS.md for the shared instructions.\n' > "${PROJECT}/CLAUDE.md"
printf '# Shared\n\nNever push to main.\n' > "${PROJECT}/AGENTS.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
grep -qF "$BEGIN_MARK" "${PROJECT}/CLAUDE.md" || fail "agents-md: block not added to CLAUDE.md when AGENTS.md is unmanaged"
grep -q 'See @AGENTS.md' "${PROJECT}/CLAUDE.md" || fail "agents-md: import line lost"
if grep -qF "$BEGIN_MARK" "${PROJECT}/AGENTS.md"; then
    fail "agents-md: AGENTS.md touched although only claude was selected"
fi
pass "agents-md adds the block to an importing CLAUDE.md when AGENTS.md is unmanaged"

# 1p. CLAUDE.md symlinked to AGENTS.md (a common setup). Claude-only: the block
#     is written through the link, which survives, and AGENTS.md gets it once.
#     Both agents: the shared file is still touched once, no duplicate block.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak* "${PROJECT}/AGENTS.md" "${PROJECT}"/AGENTS.md.bak*
printf '# Shared\n\nNever push to main.\n' > "${PROJECT}/AGENTS.md"
ln -s AGENTS.md "${PROJECT}/CLAUDE.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
[ -L "${PROJECT}/CLAUDE.md" ] || fail "agents-md: symlinked CLAUDE.md replaced by a regular file"
[ "$(grep -cF "$BEGIN_MARK" "${PROJECT}/AGENTS.md")" -eq 1 ] \
    || fail "agents-md: block not written once through the CLAUDE.md symlink"
grep -q 'Never push to main.' "${PROJECT}/AGENTS.md" || fail "agents-md: linked AGENTS.md content lost"
bash "$INSTALL" agents-md --agents claude,codex --source "$SOURCE" >/dev/null
[ -L "${PROJECT}/CLAUDE.md" ] || fail "agents-md: symlinked CLAUDE.md replaced on re-run"
[ "$(grep -cF "$BEGIN_MARK" "${PROJECT}/AGENTS.md")" -eq 1 ] \
    || fail "agents-md: block duplicated through the CLAUDE.md symlink"
pass "agents-md writes through a CLAUDE.md -> AGENTS.md symlink and never duplicates the block"

# 1q. A developer file with a legacy heading that mentions jmix-* things which are
#     not toolkit skills (jmix-flowui, a jmix-framework URL) is NOT legacy: append.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak* "${PROJECT}/AGENTS.md" "${PROJECT}"/AGENTS.md.bak*
printf '# Coding Guidelines\n\nWe use jmix-flowui; see https://github.com/jmix-framework/jmix.\n' \
    > "${PROJECT}/CLAUDE.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
grep -q 'We use jmix-flowui' "${PROJECT}/CLAUDE.md" \
    || fail "agents-md: developer file mentioning jmix-flowui was misdetected as legacy and replaced"
grep -qF "$BEGIN_MARK" "${PROJECT}/CLAUDE.md" || fail "agents-md: block not appended to jmix-flowui file"
pass "agents-md does not treat jmix-flowui / jmix-framework mentions as a legacy signal"

# Backups are first-class changes in the Studio summary, not only log text.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak*
printf '# Team rules\n\nKeep this.\n' > "${PROJECT}/CLAUDE.md"
marker_output="$(JMIX_EMIT_CHANGE_MARKERS=1 bash "$INSTALL" agents-md \
    --agents claude --source "$SOURCE")"
printf '%s\n' "$marker_output" | grep -q $'@@JMIX_CHANGE@@\taction=backed-up\ttype=file\tpath=' \
    || fail "agents-md: backup not emitted as a Studio change marker"
pass "agents-md reports a created backup to Studio"

# 1r. The earliest "# Coding Guidelines" vintage, trimmed down to its "## Skills
#     and MCP" section with no skill name left: still recognised as legacy.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak*
printf '# Coding Guidelines\n\nThis file provides guidance to AI coding agents.\n\n## Skills and MCP\n\n- ALWAYS use the Skill tool.\n' \
    > "${PROJECT}/CLAUDE.md"
bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null
cmp -s "${PROJECT}/CLAUDE.md" "$BLOCK" \
    || fail "agents-md: early-vintage file with only a 'Skills and MCP' section not replaced"
pass "agents-md replaces an early-vintage file recognised by its 'Skills and MCP' section"

# 1s. A destination that exists but is not a file is an error, not a merge.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak*
mkdir "${PROJECT}/CLAUDE.md"
if bash "$INSTALL" agents-md --agents claude --source "$SOURCE" >/dev/null 2>&1; then
    fail "agents-md: a directory named CLAUDE.md should fail"
fi
rmdir "${PROJECT}/CLAUDE.md"
pass "agents-md fails cleanly when the destination is a directory"

# 1t. Codex reads only the first 32 KiB of AGENTS.md, so an unmarked AGENTS.md
#     gets the block on top; a leading BOM stays first. Other files (CLAUDE.md,
#     see 1d) still get it at the end.
rm -rf "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak* "${PROJECT}/AGENTS.md" "${PROJECT}"/AGENTS.md.bak* "${PROJECT}/.junie"
printf '\357\273\277# Shared\n\nNever push to main.\n' > "${PROJECT}/AGENTS.md"
bash "$INSTALL" agents-md --agents codex --source "$SOURCE" >/dev/null
[ "$(head -c 3 "${PROJECT}/AGENTS.md")" = $'\xef\xbb\xbf' ] || fail "agents-md: AGENTS.md lost its leading BOM"
[ "$(tail -c +4 "${PROJECT}/AGENTS.md" | head -n 1)" = "$BEGIN_MARK" ] \
    || fail "agents-md: the block is not on top of an unmarked AGENTS.md"
[ "$(tail -n 3 "${PROJECT}/AGENTS.md")" = "$(printf '# Shared\n\nNever push to main.')" ] \
    || fail "agents-md: developer content of AGENTS.md lost"
[ -f "${PROJECT}/AGENTS.md.bak" ] || fail "agents-md: AGENTS.md not backed up"
[ ! -e "${PROJECT}/CLAUDE.md" ] || fail "agents-md: --agents codex wrote CLAUDE.md"
pass "agents-md puts the block on top of an unmarked AGENTS.md"

# 1u. Codex: a block past 32 KiB and an AGENTS.override.md are reported.
rm -f "${PROJECT}/AGENTS.md" "${PROJECT}"/AGENTS.md.bak*
awk 'BEGIN { for (i = 0; i < 700; i++) print "Rule " i ": keep the build green and the tests fast." }' > "${PROJECT}/AGENTS.md"
cat "$BLOCK" >> "${PROJECT}/AGENTS.md"
printf 'local rules\n' > "${PROJECT}/AGENTS.override.md"
out="$(bash "$INSTALL" agents-md --agents codex --source "$SOURCE")"
case "$out" in *"first 32 KiB"*) ;; *) fail "agents-md: no warning for a block past Codex's 32 KiB" ;; esac
case "$out" in *"AGENTS.override.md"*) ;; *) fail "agents-md: no warning for AGENTS.override.md" ;; esac
rm -f "${PROJECT}/AGENTS.md" "${PROJECT}/AGENTS.override.md"
pass "agents-md warns when Codex would not see the block"

# 1v. Junie follows the shared convention: its block goes into the root
#     AGENTS.md like codex/opencode, and .junie/AGENTS.md / .junie/guidelines.md
#     are not touched.
rm -f "${PROJECT}/AGENTS.md" "${PROJECT}"/AGENTS.md.bak*
mkdir -p "${PROJECT}/.junie"
printf '# Junie rules\n' > "${PROJECT}/.junie/AGENTS.md"
printf '# Old Junie rules\n' > "${PROJECT}/.junie/guidelines.md"
cp "${PROJECT}/.junie/AGENTS.md" "${WORK}/ja"; cp "${PROJECT}/.junie/guidelines.md" "${WORK}/jg"
bash "$INSTALL" agents-md --agents opencode,junie --source "$SOURCE" >/dev/null
cmp -s "${PROJECT}/AGENTS.md" "$BLOCK" || fail "agents-md: Junie's block not written to the root AGENTS.md"
[ ! -e "${PROJECT}/CLAUDE.md" ] || fail "agents-md: --agents opencode,junie wrote CLAUDE.md"
cmp -s "${PROJECT}/.junie/AGENTS.md" "${WORK}/ja" && cmp -s "${PROJECT}/.junie/guidelines.md" "${WORK}/jg" \
    || fail "agents-md: a .junie guidelines file was modified"
rm -rf "${PROJECT}/AGENTS.md" "${PROJECT}/.junie"
pass "agents-md writes Junie's block into the shared AGENTS.md"

# 1za. A NUL byte in AGENTS.md (grep calls it binary) does not stop the agents
#      after codex.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak* "${PROJECT}"/AGENTS.md.bak*
printf '# Rules\nx\000y\n' > "${PROJECT}/AGENTS.md"
bash "$INSTALL" agents-md --agents codex,claude --source "$SOURCE" >/dev/null 2>&1 \
    || fail "agents-md: a NUL byte in AGENTS.md failed the step"
[ -f "${PROJECT}/CLAUDE.md" ] || fail "agents-md: claude skipped after a binary-looking AGENTS.md"
rm -f "${PROJECT}/AGENTS.md" "${PROJECT}"/AGENTS.md.bak* "${PROJECT}/CLAUDE.md"
pass "agents-md handles an AGENTS.md that grep calls binary"

# Reset so later sections start from a clean project guidelines state.
rm -f "${PROJECT}/CLAUDE.md" "${PROJECT}"/CLAUDE.md.bak* "${PROJECT}/AGENTS.md" "${PROJECT}"/AGENTS.md.bak*

# ---------------------------------------------------------------------------
# 2. skills, local scope (per-skill symlinks into agent dirs)
# ---------------------------------------------------------------------------
bash "$INSTALL" skills --agents claude,codex,opencode,junie --scope local --source "$SOURCE" >/dev/null
[ -d "${PROJECT}/.skills" ] || fail "skills(local): .skills store missing"
find "${PROJECT}/.skills" -maxdepth 1 -mindepth 1 -name 'jmix-*' -type d | grep -q . \
    || fail "skills(local): store has no jmix-* folders"
for rel in ".claude/skills" ".agents/skills"; do
    [ -e "${PROJECT}/${rel}/${SKILL}/SKILL.md" ] \
        || fail "skills(local): ${rel}/${SKILL} does not resolve"
done
[ ! -e "${PROJECT}/.junie/skills" ] || fail "skills(local): Junie got a .junie/skills dir; it reads .agents/skills"
pass "skills(local) builds store and resolving symlinks for all agents"

CONV_PROJ="${WORK}/conventions-project"
mkdir -p "$CONV_PROJ"
(cd "$CONV_PROJ" && bash "$INSTALL" skills --conventions claude --scope local --source "$SOURCE" >/dev/null) \
    || fail "skills: --conventions claude failed"
[ -e "${CONV_PROJ}/.claude/skills/${SKILL}/SKILL.md" ] && [ ! -e "${CONV_PROJ}/.agents" ] \
    || fail "skills: --conventions claude did not link .claude/skills alone"
(cd "$CONV_PROJ" && bash "$INSTALL" skills --conventions agents --scope local --source "$SOURCE" >/dev/null) \
    || fail "skills: --conventions agents failed"
[ -e "${CONV_PROJ}/.agents/skills/${SKILL}/SKILL.md" ] || fail "skills: --conventions agents did not link .agents/skills"
rm -rf "$CONV_PROJ"
pass "skills takes --conventions agents,claude"

for rel in ".claude/skills" ".agents/skills"; do
    tgt="$(readlink "${PROJECT}/${rel}/${SKILL}")"
    case "$tgt" in
        /*) fail "skills(local): ${rel}/${SKILL} target is absolute (${tgt}); must be relative" ;;
    esac
done
pass "skills(local) symlink targets are relative (portable across clones)"

# Links an earlier version put into .junie/skills are removed (Junie's CLI
# reads that dir first, so they would shadow newer skills); other skills stay.
mkdir -p "${PROJECT}/.junie/skills/my-skill"
ln -s ../../.skills/jmix "${PROJECT}/.junie/skills/jmix"
ln -s ../../.skills/jmix-create-entity "${PROJECT}/.junie/skills/jmix-create-entity"
out="$(bash "$INSTALL" skills --agents codex --scope local --source "$SOURCE")"
[ ! -e "${PROJECT}/.junie/skills/jmix" ] && [ ! -L "${PROJECT}/.junie/skills/jmix-create-entity" ] \
    || fail "skills(local): old toolkit links in .junie/skills not removed"
[ -d "${PROJECT}/.junie/skills/my-skill" ] || fail "skills(local): removed a foreign skill from .junie/skills"
case "$out" in *"Removed old Junie skill link"*) ;; *) fail "skills(local): removal of old Junie links not reported" ;; esac
rm -rf "${PROJECT}/.junie"
pass "skills removes the old .junie/skills links and keeps foreign skills"

# Without an agent that reads .agents/skills nothing replaces those links, so
# they stay: removing them would leave Junie with no Jmix skills.
mkdir -p "${PROJECT}/.junie/skills"
ln -s ../../.skills/jmix-create-entity "${PROJECT}/.junie/skills/jmix-create-entity"
bash "$INSTALL" skills --agents claude --scope local --source "$SOURCE" >/dev/null
[ -L "${PROJECT}/.junie/skills/jmix-create-entity" ] \
    || fail "skills(local): old Junie links removed although no agent re-linked .agents/skills"
rm -rf "${PROJECT}/.junie"
pass "skills keeps the old .junie/skills links when no agent reads .agents/skills"

# A .junie/skills that is the same dir as an agent skills dir holds the links
# this run just created: the cleanup leaves it alone.
mkdir -p "${PROJECT}/.junie"
ln -s ../.agents/skills "${PROJECT}/.junie/skills"
out="$(bash "$INSTALL" skills --agents codex,junie --scope local --source "$SOURCE")"
[ -e "${PROJECT}/.agents/skills/${SKILL}/SKILL.md" ] \
    || fail "skills(local): links deleted through a .junie/skills -> .agents/skills symlink"
case "$out" in *"Removed old Junie skill link"*) fail "skills(local): removed links from a .junie/skills shared with .agents/skills" ;; esac
rm -rf "${PROJECT}/.junie"
pass "skills keeps the links of a .junie/skills shared with .agents/skills"

# Store backups (--backup-existing-files) are not skills: they are not linked,
# and a link to one that an earlier version made is removed.
ln -s "../../.skills/${SKILL}.bak" "${PROJECT}/.claude/skills/${SKILL}.bak"
bash "$INSTALL" skills --agents claude --scope local --backup-existing-files --source "$SOURCE" >/dev/null
[ -d "${PROJECT}/.skills/${SKILL}.bak" ] || fail "skills(local): --backup-existing-files made no store backup"
for link in "${PROJECT}/.claude/skills"/*.bak*; do
    [ ! -e "$link" ] && [ ! -L "$link" ] || fail "skills(local): store backup $(basename "$link") linked as a skill"
done
rm -rf "${PROJECT}/.skills"/*.bak*
pass "skills does not link store backups as skills"

# An agent skills dir that is the store itself already has the skills; linking
# them into it would replace every skill with a link to itself.
# A store an earlier version already turned into such links is repaired.
SELF_PROJ="${WORK}/self-link-project"
mkdir -p "${SELF_PROJ}/.claude" "${SELF_PROJ}/.skills"
ln -s ../.skills "${SELF_PROJ}/.claude/skills"
ln -s "./${SKILL}" "${SELF_PROJ}/.skills/${SKILL}"
for run in 1 2; do
    out="$(cd "$SELF_PROJ" && bash "$INSTALL" skills --agents claude --scope local --source "$SOURCE")" \
        || fail "skills(local): run ${run} failed with .claude/skills -> ../.skills"
done
case "$out" in
    *"Linked skills into"*) fail "skills(local): reported linking into the store itself" ;;
    *"is the skills store itself"*) ;;
    *) fail "skills(local): no note that .claude/skills is the store" ;;
esac
[ -f "${SELF_PROJ}/.skills/${SKILL}/SKILL.md" ] && [ ! -L "${SELF_PROJ}/.skills/${SKILL}" ] \
    || fail "skills(local): store destroyed when .claude/skills is the store"
rm -rf "$SELF_PROJ"
pass "skills leaves the store alone when an agent skills dir is the store"

# ---------------------------------------------------------------------------
# 3. skills, global scope (under $HOME) -- store keyed by the branch (CONTENT_REF)
# ---------------------------------------------------------------------------
bash "$INSTALL" skills --agents claude --scope global --source "$SOURCE" >/dev/null
[ -d "${HOME}/.agents/.jmix/skills/v3" ]                  || fail "skills(global): v3 store missing"
[ -e "${HOME}/.claude/skills/${SKILL}/SKILL.md" ]         || fail "skills(global): symlink does not resolve"
pass "skills(global) builds v3 store under HOME and resolving symlink"

# An agent skills dir that is itself a symlink to another agent's dir (a common
# way to share skills, here ~/.agents/skills -> ~/.claude/skills) gets links
# relative to where they physically live, so every link still resolves.
mkdir -p "${HOME}/.agents"
ln -s ../.claude/skills "${HOME}/.agents/skills"
bash "$INSTALL" skills --agents claude,codex --scope global --source "$SOURCE" >/dev/null
for link in "${HOME}/.claude/skills"/jmix*; do
    [ -e "${link}/SKILL.md" ] || fail "skills(global): $(basename "$link") broken through a symlinked ~/.agents/skills"
done
rm -f "${HOME}/.agents/skills"
pass "skills(global) links resolve when ~/.agents/skills is a symlink to ~/.claude/skills"

# The other way round, ~/.agents/skills -> ~/.junie/skills: the old-Junie-link
# cleanup must not delete the links just created through ~/.agents/skills.
mkdir -p "${HOME}/.junie/skills"
ln -s ../.junie/skills "${HOME}/.agents/skills"
bash "$INSTALL" skills --agents codex --scope global --source "$SOURCE" >/dev/null
[ -e "${HOME}/.agents/skills/${SKILL}/SKILL.md" ] \
    || fail "skills(global): links deleted through ~/.agents/skills -> ~/.junie/skills"
rm -f "${HOME}/.agents/skills"
rm -rf "${HOME}/.junie"
pass "skills(global) keeps the links when ~/.agents/skills is a symlink to ~/.junie/skills"

if bash "$INSTALL" skills --agents claude-desktop --scope global --source "$SOURCE" >/dev/null 2>&1; then
    fail "skills: claude-desktop takes no skills and should be rejected"
fi
pass "skills rejects claude-desktop"

# Studio can pin a feature branch independently of the release default. The
# resolved ref keys the global store and is accepted by every subcommand via
# the common argument pre-parser.
bash "$INSTALL" skills --content-ref no-agents-md-test --agents claude \
    --scope global --source "$SOURCE" >/dev/null
[ -d "${HOME}/.agents/.jmix/skills/no-agents-md-test" ] \
    || fail "skills(global): content-ref override did not key the store"
pass "skills(global) honours --content-ref"

# Every Studio command must pass the same resolved branch to the script it
# downloads; otherwise a feature-branch script silently fetches v3 content.
[ "$(grep -o -- '--content-ref' "${SOURCE}/.studio/studio-meta-data.json" | wc -l | tr -d ' ')" -eq 6 ] \
    || fail "studio metadata: a macOS/Linux command omits --content-ref"
[ "$(grep -o -- '-ContentRef' "${SOURCE}/.studio/studio-meta-data.json" | wc -l | tr -d ' ')" -eq 3 ] \
    || fail "studio metadata: a Windows command omits -ContentRef"
pass "Studio commands pass the resolved content ref"

# ---------------------------------------------------------------------------
# 5. MCP servers. 5a-5r: at user level (--scope global) in the isolated HOME;
#    5s on: in the project (--scope local, the default). Files are merged in
#    place (the assertions use jq).
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
    MCP_PROJ="${WORK}/mcp-project"
    # .git ends the walk over parent project configs that Codex merges in.
    mkdir -p "$MCP_PROJ/.git" "${WORK}/bin"
    cd "$MCP_PROJ"
    # Fake agent CLIs. Only Claude Code goes through its CLI (`claude mcp add`),
    # whose arguments the fake records (and echoes, like the real one does).
    printf '#!/bin/sh\necho "$*" >> "%s/claude.log"\necho "added: $*"\n' "$WORK" > "${WORK}/bin/claude"
    printf '#!/bin/sh\necho called >> "%s/codex.log"\nexit 99\n' "$WORK" > "${WORK}/bin/codex"
    chmod +x "${WORK}/bin/claude" "${WORK}/bin/codex"
    BIN_PATH="${WORK}/bin:${PATH}"
    case "$(uname -s)" in
        Darwin) DESKTOP_DIR="${HOME}/Library/Application Support/Claude" ;;
        *)      DESKTOP_DIR="${HOME}/.config/Claude" ;;
    esac
    USER_CODEX="${HOME}/.codex/config.toml"
    USER_OC="${HOME}/.config/opencode/opencode.json"
    USER_JUNIE="${HOME}/.junie/mcp/mcp.json"
    project_untouched() {
        [ -z "$(find "$MCP_PROJ" -mindepth 1 -maxdepth 1 ! -name .git)" ]
    }

    # 5a. IDE MCP server not reachable -> Streamable HTTP (/stream). Foreign
    #     servers and keys survive; an old [mcp_servers.jetbrains] table and its
    #     sub-table are replaced; nothing lands in the project.
    mkdir -p "$(dirname "$USER_CODEX")" "$(dirname "$USER_OC")"
    printf '{\n  "$schema": "keep-me",\n  "mcp": {"mine": {"type": "remote", "url": "http://mine"}}\n}\n' > "$USER_OC"
    printf 'model = "o3"\n\n[mcp_servers.jetbrains]\ncommand = "java"\n\n[mcp_servers.jetbrains.env]\nIJ_MCP_SERVER_PORT = "64342"\n\n[mcp_servers.mine]\nurl = "http://mine"\n' \
        > "$USER_CODEX"
    PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --scope global --agents claude,codex,opencode,junie >/dev/null \
        || fail "mcp-jetbrains: non-zero exit"
    grep -qF -- '--scope user --transport http jetbrains http://127.0.0.1:9/stream' "${WORK}/claude.log" \
        || fail "mcp-jetbrains: wrong claude mcp add arguments"
    [ ! -e "${WORK}/codex.log" ] || fail "mcp-jetbrains: called the codex CLI"
    grep -q '^model = "o3"$' "$USER_CODEX" && grep -q '^\[mcp_servers.mine\]$' "$USER_CODEX" \
        || fail "mcp-jetbrains: other Codex config lost"
    [ "$(grep -c '^\[mcp_servers.jetbrains' "$USER_CODEX")" -eq 1 ] && ! grep -q 'IJ_MCP_SERVER_PORT' "$USER_CODEX" \
        || fail "mcp-jetbrains: old Codex jetbrains table not replaced"
    grep -q '^url = "http://127.0.0.1:9/stream"$' "$USER_CODEX" || fail "mcp-jetbrains: Codex url missing"
    jq -e '.mcp.jetbrains == {"type":"remote","url":"http://127.0.0.1:9/stream","enabled":true}
           and .mcp.mine.url == "http://mine" and ."$schema" == "keep-me"' "$USER_OC" >/dev/null \
        || fail "mcp-jetbrains: opencode entry wrong or other content lost"
    [ ! -e "$USER_JUNIE" ] || fail "mcp-jetbrains: Junie got a JetBrains MCP entry it does not need"
    project_untouched || fail "mcp-jetbrains: wrote into the project"
    pass "mcp-jetbrains registers every agent in its user config, nothing in the project"

    # 5b. A re-run changes nothing.
    cp "$USER_CODEX" "${WORK}/c1"; cp "$USER_OC" "${WORK}/o1"
    out="$(PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --scope global --agents codex,opencode)" \
        || fail "mcp-jetbrains: re-run non-zero exit"
    cmp -s "$USER_CODEX" "${WORK}/c1" && cmp -s "$USER_OC" "${WORK}/o1" || fail "mcp-jetbrains: re-run changed a file"
    case "$out" in *"Updated: "*|*"Created: "*) fail "mcp-jetbrains: re-run reported a change" ;; esac
    pass "mcp-jetbrains re-run leaves the files unchanged"

    # 5c. A file the merge cannot parse (JSONC) is left alone and the step fails;
    #     the agents after it are still configured.
    cp "$USER_OC" "${WORK}/o-valid"
    printf '{\n  // mine\n  "theme": "dark"\n}\n' > "$USER_OC"
    cp "$USER_OC" "${WORK}/o2"
    : > "${WORK}/claude.log"
    if PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --scope global --agents opencode,claude >/dev/null 2>&1; then
        fail "mcp-jetbrains: a JSONC opencode.json should fail the step"
    fi
    cmp -s "$USER_OC" "${WORK}/o2" || fail "mcp-jetbrains: JSONC opencode.json was modified"
    grep -q jetbrains "${WORK}/claude.log" || fail "mcp-jetbrains: a failed agent stopped the agents after it"
    cp "${WORK}/o-valid" "$USER_OC"
    pass "mcp-jetbrains leaves an unparsable opencode.json untouched, fails, and continues"

    # 5d. A server defined inline (not as a [table]) is refused, not duplicated.
    cp "$USER_CODEX" "${WORK}/c-valid"
    printf '[mcp_servers]\njetbrains = { url = "http://mine" }\n' > "$USER_CODEX"
    cp "$USER_CODEX" "${WORK}/c2"
    if PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --scope global --agents codex >/dev/null 2>&1; then
        fail "mcp-jetbrains: an inline Codex jetbrains entry should fail the step"
    fi
    cmp -s "$USER_CODEX" "${WORK}/c2" || fail "mcp-jetbrains: inline Codex entry was modified"
    cp "${WORK}/c-valid" "$USER_CODEX"
    pass "mcp-jetbrains refuses to touch an inline Codex jetbrains entry"

    # 5e. IntelliJ IDEA before 2026.1 answers 404 on /stream: SSE for Claude and
    #     OpenCode, a stdio bridge for Codex (no SSE transport there).
    if command -v python3 >/dev/null 2>&1; then
        python3 - "${WORK}/port" <<'PY' &
import http.server, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(404); self.end_headers()
    do_GET = do_HEAD
    def log_message(self, *args):
        pass
# Plain TCPServer: HTTPServer's bind does a reverse DNS lookup (getfqdn) that
# can hang for half a minute on a CI macOS runner.
s = socketserver.TCPServer(("127.0.0.1", 0), H)
with open(sys.argv[1], "w") as f:
    f.write(str(s.server_address[1]))
s.serve_forever()
PY
        server_pid=$!
        disown "$server_pid"   # no job-status noise when it is killed below
        # A cold python3 start on a CI macOS runner can take several seconds.
        waited=0
        while [ ! -s "${WORK}/port" ] && [ "$waited" -lt 60 ]; do sleep 0.5; waited=$((waited + 1)); done
        [ -s "${WORK}/port" ] || fail "mcp-jetbrains(sse): the fake IDE server did not start within 30 s"
        port="$(cat "${WORK}/port")"
        JMIX_IDE_MCP_PORT="$port" PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --scope global --agents claude,codex,opencode >/dev/null \
            || fail "mcp-jetbrains(sse): non-zero exit"
        kill "$server_pid" 2>/dev/null || true
        grep -qF -- "--scope user --transport sse jetbrains http://127.0.0.1:${port}/sse" "${WORK}/claude.log" \
            || fail "mcp-jetbrains(sse): Claude entry is not SSE"
        grep -q "^args = \[\"-y\", \"mcp-remote\", \"http://127.0.0.1:${port}/sse\", \"--transport\", \"sse-only\"\]$" "$USER_CODEX" \
            || fail "mcp-jetbrains(sse): Codex has no mcp-remote bridge"
        jq -e --arg u "http://127.0.0.1:${port}/sse" '.mcp.jetbrains.url == $u' "$USER_OC" >/dev/null \
            || fail "mcp-jetbrains(sse): OpenCode entry is not SSE"
        PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --scope global --agents codex,opencode >/dev/null \
            || fail "mcp-jetbrains: switching back to /stream failed"
        pass "mcp-jetbrains falls back to SSE (and a Codex bridge) on IntelliJ IDEA before 2026.1"
    else
        echo "skip: python3 not found, skipping the SSE fallback test"
    fi

    # 5f. Claude Desktop is set up together with claude, and only when it is
    #     installed (its config folder exists); its own settings are kept and
    #     the restart reminder appears only when its file changed.
    out="$(PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --scope global --agents claude 2>&1)" \
        || fail "mcp-jetbrains: a missing Claude Desktop should not fail the step"
    [ ! -e "$DESKTOP_DIR" ] || fail "mcp-jetbrains: created a Claude Desktop config folder"
    case "$out" in *"Claude Desktop"*) fail "mcp-jetbrains: mentioned a Claude Desktop that is not installed" ;; esac
    mkdir -p "$DESKTOP_DIR"
    printf '{"preferences": {"keep": true}}' > "${DESKTOP_DIR}/claude_desktop_config.json"
    out="$(PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --scope global --agents claude)" \
        || fail "mcp-jetbrains(desktop): non-zero exit"
    jq -e '.preferences.keep == true and .mcpServers.jetbrains.command == "npx"
           and (.mcpServers.jetbrains.args | index("mcp-remote"))' "${DESKTOP_DIR}/claude_desktop_config.json" >/dev/null \
        || fail "mcp-jetbrains(desktop): bridge entry missing or preferences lost"
    case "$out" in *"Quit Claude Desktop"*) ;; *) fail "mcp-jetbrains(desktop): no restart reminder after a change" ;; esac
    out="$(PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --scope global --agents claude)"
    case "$out" in *"Quit Claude Desktop"*) fail "mcp-jetbrains(desktop): restart reminder for an unchanged file" ;; esac
    if bash "$INSTALL" mcp-jetbrains --scope global --agents claude-desktop >/dev/null 2>&1; then
        fail "mcp-jetbrains: claude-desktop is no longer a separate agent"
    fi
    pass "claude also sets up an installed Claude Desktop, through a stdio bridge"

    # 5g. Context7: the key never reaches the output or the project, and the
    #     user files holding it are private.
    out="$(PATH="$BIN_PATH" bash "$INSTALL" mcp-context7 --scope global --agents claude,codex,opencode,junie \
        --context7-key ctx7sk-TESTKEY 2>&1)" || fail "mcp-context7: non-zero exit"
    case "$out" in *TESTKEY*) fail "mcp-context7: the API key was printed" ;; esac
    grep -qF -- '--scope user --transport http context7 https://mcp.context7.com/mcp --header Authorization: Bearer ctx7sk-TESTKEY' \
        "${WORK}/claude.log" || fail "mcp-context7: wrong claude mcp add arguments"
    grep -qF 'http_headers = { Authorization = "Bearer ctx7sk-TESTKEY" }' "$USER_CODEX" \
        || fail "mcp-context7: Codex user config entry wrong"
    jq -e '.mcp.context7.headers.Authorization == "Bearer ctx7sk-TESTKEY"' "$USER_OC" >/dev/null \
        || fail "mcp-context7: OpenCode user config entry wrong"
    jq -e '.mcpServers.context7.env.CONTEXT7_API_KEY == "ctx7sk-TESTKEY"' "$USER_JUNIE" >/dev/null \
        || fail "mcp-context7: Junie user config entry wrong"
    jq -e '.mcpServers.context7.env.CONTEXT7_API_KEY == "ctx7sk-TESTKEY" and .preferences.keep == true' \
        "${DESKTOP_DIR}/claude_desktop_config.json" >/dev/null || fail "mcp-context7: Claude Desktop entry wrong"
    project_untouched || fail "mcp-context7: wrote into the project"
    for f in "$USER_CODEX" "$USER_OC" "$USER_JUNIE" "${DESKTOP_DIR}/claude_desktop_config.json"; do
        [ "$(file_mode "$f")" = 600 ] || fail "mcp-context7: ${f} holds the key but is not 0600"
    done
    if bash "$INSTALL" mcp-context7 --scope global --agents codex --context7-key 'bad"key' >/dev/null 2>&1; then
        fail "mcp-context7: a key with a quote should be rejected"
    fi
    pass "mcp-context7 registers every agent without printing the key"

    # 5h. An invalid --scope is refused; the claude CLI is also found where its
    #     installers put it, off PATH (an IDE started from the desktop often
    #     lacks ~/.local/bin).
    if bash "$INSTALL" playwright --agents codex --scope nowhere >/dev/null 2>&1; then
        fail "playwright: an invalid --scope should fail"
    fi
    out="$(PATH=/usr/bin:/bin bash "$INSTALL" playwright --agents claude --scope global 2>&1)" \
        || fail "playwright: a missing claude CLI should be a skip, not a failure"
    case "$out" in *"Skipped: 'claude' CLI not found"*) ;; *) fail "playwright: no skip message without a claude CLI" ;; esac
    mkdir -p "${HOME}/.local/bin"
    printf '#!/bin/sh\necho "$*" >> "%s/claude-local.log"\n' "$WORK" > "${HOME}/.local/bin/claude"
    chmod +x "${HOME}/.local/bin/claude"
    PATH=/usr/bin:/bin bash "$INSTALL" playwright --agents claude --scope global >/dev/null || fail "playwright: ~/.local/bin/claude failed"
    grep -qF -- '--scope user playwright -- npx -y @playwright/mcp@latest' "${WORK}/claude-local.log" \
        || fail "playwright: the claude CLI in ~/.local/bin was not used"
    rm -rf "${HOME}/.local"
    mkdir -p "${HOME}/.claude/local"
    printf '#!/bin/sh\necho "$*" >> "%s/claude-old.log"\n' "$WORK" > "${HOME}/.claude/local/claude"
    chmod +x "${HOME}/.claude/local/claude"
    PATH=/usr/bin:/bin bash "$INSTALL" playwright --agents claude --scope global >/dev/null || fail "playwright: ~/.claude/local/claude failed"
    grep -q 'mcp add' "${WORK}/claude-old.log" || fail "playwright: the claude CLI in ~/.claude/local was not used"
    rm -rf "${HOME}/.claude/local"
    pass "MCP steps refuse an invalid --scope and find the claude CLI off PATH"

    # 5i. Playwright for every agent. The playwright-cli skills of earlier
    #     versions are left alone.
    mkdir -p "${HOME}/.agents/.playwright/skills/playwright-cli" "${HOME}/.claude/skills"
    ln -s ../../.agents/.playwright/skills/playwright-cli "${HOME}/.claude/skills/playwright-cli"
    PATH="$BIN_PATH" bash "$INSTALL" playwright --agents claude,codex,opencode,junie --scope global >/dev/null \
        || fail "playwright: non-zero exit"
    grep -qF -- '--scope user playwright -- npx -y @playwright/mcp@latest' "${WORK}/claude.log" \
        || fail "playwright: wrong claude mcp add arguments"
    grep -q '^args = \["-y", "@playwright/mcp@latest"\]$' "$USER_CODEX" || fail "playwright: Codex entry wrong"
    jq -e '.mcp.playwright.command == ["npx","-y","@playwright/mcp@latest"]' "$USER_OC" >/dev/null \
        || fail "playwright: OpenCode entry wrong"
    jq -e '.mcpServers.playwright.args == ["-y","@playwright/mcp@latest"]' "$USER_JUNIE" >/dev/null \
        || fail "playwright: Junie entry wrong"
    [ -L "${HOME}/.claude/skills/playwright-cli" ] && [ -d "${HOME}/.agents/.playwright" ] \
        || fail "playwright: removed the old playwright-cli skills"
    rm -rf "${HOME}/.agents/.playwright" "${HOME}/.claude/skills/playwright-cli"
    project_untouched || fail "playwright: wrote into the project"
    pass "playwright registers every agent and keeps the old playwright-cli skills"

    # 5j. Codex merges the project configs of the current dir up to its git
    #     root into the user config: one with the other transport fails the
    #     step; they are read, never written.
    cp "$USER_CODEX" "${WORK}/c-before"
    mkdir -p .codex app
    printf '[mcp_servers.playwright]\nurl = "http://project"\n' > .codex/config.toml
    cp .codex/config.toml "${WORK}/p-before"
    for dir in . app; do
        if (cd "$dir" && PATH="$BIN_PATH" bash "$INSTALL" playwright --scope global --agents codex >/dev/null 2>&1); then
            fail "codex: a project table with another transport should fail the step (from ${dir})"
        fi
        cmp -s "$USER_CODEX" "${WORK}/c-before" && cmp -s .codex/config.toml "${WORK}/p-before" \
            || fail "codex: the project conflict changed a config"
    done
    [ ! -e app/.codex ] || fail "codex: wrote a project config"
    printf 'notes = """\nmulti\nline\n"""\n\n[mcp_servers.playwright]\ncommand = "npx"\n' > .codex/config.toml
    cp .codex/config.toml "${WORK}/p-before"
    (cd app && PATH="$BIN_PATH" bash "$INSTALL" playwright --scope global --agents codex >/dev/null) \
        || fail "codex: a same-transport project table (with a triple-quoted string) was rejected"
    cmp -s .codex/config.toml "${WORK}/p-before" || fail "codex: the project config was rewritten"
    for entry in '[mcp_servers]
playwright = { url = "http://project" }' 'mcp_servers.playwright.url = "http://project"'; do
        printf '%s\n' "$entry" > .codex/config.toml
        cp .codex/config.toml "${WORK}/p-before"
        if out="$(cd app && PATH="$BIN_PATH" bash "$INSTALL" playwright --scope global --agents codex 2>&1)"; then
            fail "codex: a project server defined inline or by dotted keys should fail the step"
        fi
        case "$out" in *"cannot check"*) ;; *) fail "codex: an inline project definition is not reported as unreadable" ;; esac
        cmp -s .codex/config.toml "${WORK}/p-before" && cmp -s "$USER_CODEX" "${WORK}/c-before" \
            || fail "codex: an inline project definition changed a config"
    done
    # With the IDE unreachable the transport is a guess: the error points at the
    # IDE, not at a project bridge that may well be right.
    printf '[mcp_servers.jetbrains]\ncommand = "npx"\n' > .codex/config.toml
    if out="$(PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --scope global --agents codex 2>&1)"; then
        fail "codex: a guessed transport against a project bridge should fail the step"
    fi
    case "$out" in *"not reachable to tell"*) ;; *) fail "codex: the guessed-transport conflict does not point at the IDE" ;; esac
    rm -rf .codex app
    # Outside a git repository Codex reads only the current directory's config.
    mkdir -p "${WORK}/nogit/.codex" "${WORK}/nogit/child"
    printf '[mcp_servers.playwright]\nurl = "http://parent"\n' > "${WORK}/nogit/.codex/config.toml"
    (cd "${WORK}/nogit/child" && PATH="$BIN_PATH" bash "$INSTALL" playwright --scope global --agents codex >/dev/null) \
        || fail "codex: a parent config outside a git repository failed the step"
    rm -rf "${WORK}/nogit"
    pass "Codex project configs with another transport fail the step and are never written"

    # 5k. Run from $HOME, the project config is the user config: an old stdio
    #     context7 entry there is simply replaced.
    printf '[mcp_servers.context7]\ncommand = "npx"\nargs = ["-y", "@upstash/context7-mcp", "--api-key", "old"]\n' > "$USER_CODEX"
    (cd "$HOME" && bash "$INSTALL" mcp-context7 --scope global --agents codex --context7-key ctx7sk-TESTKEY >/dev/null) \
        || fail "mcp-context7: run from \$HOME failed on its own stdio entry"
    grep -q '^url = "https://mcp.context7.com/mcp"$' "$USER_CODEX" && ! grep -q '^command' "$USER_CODEX" \
        || fail "mcp-context7: run from \$HOME did not replace the stdio entry"
    cp "${WORK}/c-before" "$USER_CODEX"
    pass "mcp-context7 run from \$HOME replaces the old stdio entry"

    # 5l. A table is replaced where it stands: the order and the comment that
    #     introduces the next table stay, and alternating steps converge.
    printf '[mcp_servers.jetbrains]\nurl = "old"\n\n# my own server\n[mcp_servers.mine]\nurl = "http://mine"\n' > "$USER_CODEX"
    PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --scope global --agents codex >/dev/null || fail "toml: non-zero exit"
    [ "$(sed -n 1p "$USER_CODEX")" = '[mcp_servers.jetbrains]' ] || fail "toml: replaced table moved"
    grep -q '^# my own server$' "$USER_CODEX" || fail "toml: comment before the next table lost"
    PATH="$BIN_PATH" bash "$INSTALL" playwright --scope global --agents codex >/dev/null || fail "toml: playwright non-zero exit"
    cp "$USER_CODEX" "${WORK}/c3"
    out="$(PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --scope global --agents codex; PATH="$BIN_PATH" bash "$INSTALL" playwright --agents codex)" \
        || fail "toml: alternating steps failed"
    cmp -s "$USER_CODEX" "${WORK}/c3" || fail "toml: alternating steps keep rewriting config.toml"
    case "$out" in *"Updated: "*) fail "toml: an unchanged config.toml was reported as updated" ;; esac
    pass "toml tables are replaced in place and re-runs converge"

    # 5m. Unsupported TOML is refused and the file kept: a triple-quoted string
    #     (in a file the step has to write), a root inline table, dotted keys.
    #     A quoted key is fine, and a BOM before the first header does not
    #     duplicate the table.
    for entry in 'notes = """
multi
"""' "notes = '''
multi
'''" 'mcp_servers = { jetbrains = { url = "x" } }' '[mcp_servers]
jetbrains = { command = "java", args = [] }' 'mcp_servers.jetbrains.command = "java"'; do
        printf '%s\n' "$entry" > "$USER_CODEX"
        cp "$USER_CODEX" "${WORK}/c4"
        if PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --scope global --agents codex >/dev/null 2>&1; then
            fail "toml: unsupported syntax should fail the step: ${entry}"
        fi
        cmp -s "$USER_CODEX" "${WORK}/c4" || fail "toml: unsupported syntax was modified: ${entry}"
    done
    printf '[mcp_servers.jetbrains]\n"url" = "http://old"\n' > "$USER_CODEX"
    PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --scope global --agents codex >/dev/null || fail "toml: quoted key non-zero exit"
    ! grep -q 'http://old' "$USER_CODEX" || fail "toml: quoted url key survived"
    printf '\357\273\277[mcp_servers.jetbrains]\nurl = "old"\n' > "$USER_CODEX"
    PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --scope global --agents codex >/dev/null || fail "toml: BOM file non-zero exit"
    [ "$(grep -c 'mcp_servers.jetbrains' "$USER_CODEX")" -eq 1 ] || fail "toml: BOM header duplicated the table"
    [ "$(head -c 3 "$USER_CODEX")" = $'\xef\xbb\xbf' ] || fail "toml: leading BOM lost"
    cp "${WORK}/c-before" "$USER_CODEX"
    pass "toml refuses unsupported syntax and handles quoted keys and a leading BOM"

    # 5n. An unreadable config, or a directory at its path, is reported and
    #     kept, never replaced.
    if [ "$(id -u)" != 0 ]; then
        chmod 000 "$USER_OC"
        if PATH="$BIN_PATH" bash "$INSTALL" playwright --scope global --agents opencode >/dev/null 2>&1; then
            fail "json: an unreadable opencode.json should fail the step"
        fi
        chmod 600 "$USER_OC"
        jq -e '.mcp.mine' "$USER_OC" >/dev/null || fail "json: an unreadable opencode.json was replaced"
    fi
    mv "$USER_OC" "${WORK}/o-saved"
    mkdir "$USER_OC"
    if PATH="$BIN_PATH" bash "$INSTALL" playwright --scope global --agents opencode >/dev/null 2>&1; then
        fail "json: a directory at the config path should fail"
    fi
    [ -z "$(ls -A "$USER_OC")" ] || fail "json: staged data was moved into a config directory"
    rmdir "$USER_OC"
    mv "${WORK}/o-saved" "$USER_OC"
    pass "an unreadable config or a directory at its path fails the step and is kept"

    # 5o. Without jq and node a new JSON config is still created (no merge
    #     needed), and a re-run finds it unchanged.
    mkdir -p "${WORK}/minbin"
    for tool in awk sed grep mktemp cmp chmod mv cat dirname basename head tail tr rm mkdir uname cut stat cp ln readlink id; do
        p="$(command -v "$tool" 2>/dev/null)" && ln -sf "$p" "${WORK}/minbin/${tool}"
    done
    mkdir -p "${WORK}/nojq" && cd "${WORK}/nojq"
    HOME="${WORK}/nojq" PATH="${WORK}/minbin" /bin/bash "$INSTALL" playwright --scope global --agents opencode,junie >/dev/null \
        || fail "json: creating configs without jq/node failed"
    jq -e '.mcp.playwright.type == "local"' "${WORK}/nojq/.config/opencode/opencode.json" >/dev/null \
        && jq -e '.mcpServers.playwright.command == "npx"' "${WORK}/nojq/.junie/mcp/mcp.json" >/dev/null \
        || fail "json: configs created without jq/node are wrong"
    out="$(HOME="${WORK}/nojq" PATH="${WORK}/minbin" /bin/bash "$INSTALL" playwright --scope global --agents opencode,junie)" \
        || fail "json: re-run without jq/node failed"
    case "$out" in *"Updated: "*|*"Created: "*) fail "json: re-run without jq/node rewrote a config" ;; esac
    cd "$MCP_PROJ"
    pass "JSON configs are created and re-checked without jq or node"

    # 5p. An existing user config that gets the Context7 key ends up private.
    chmod 644 "$USER_OC"
    bash "$INSTALL" mcp-context7 --scope global --agents opencode --context7-key ctx7sk-TESTKEY >/dev/null || fail "mcp-context7: re-run failed"
    [ "$(file_mode "$USER_OC")" = 600 ] || fail "mcp-context7: a 0644 opencode.json kept its mode after getting the key"
    pass "mcp-context7 makes an existing user config private"

    # 5r. Misc: a bad port is refused up front, --source is accepted, and the
    #     Claude Desktop restart reminder appears only when it was written.
    if JMIX_IDE_MCP_PORT='9"x' bash "$INSTALL" mcp-jetbrains --scope global --agents codex >/dev/null 2>&1; then
        fail "a JMIX_IDE_MCP_PORT that is not a number should fail"
    fi
    PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --scope global --agents codex --source "$SOURCE" >/dev/null \
        || fail "mcp-jetbrains: --source should be accepted"
    rm -rf "$DESKTOP_DIR"
    out="$(PATH="$BIN_PATH" bash "$INSTALL" playwright --scope global --agents claude)"
    case "$out" in *"Quit Claude Desktop"*) fail "restart reminder printed without Claude Desktop" ;; esac
    pass "port validation, --source and the Claude Desktop reminder"

    # 5s. Local scope (the default): the project files of every agent, merged
    #     in place; Claude Code needs no CLI there.
    LOCAL_PROJ="${WORK}/local-project"
    mkdir -p "$LOCAL_PROJ/.git" "$LOCAL_PROJ/.codex"
    cd "$LOCAL_PROJ"
    printf '{\n  "$schema": "keep-me",\n  "mcpServers": {"mine": {"type": "http", "url": "http://mine"}}\n}\n' > .mcp.json
    printf 'model = "o3"\n\n[mcp_servers.mine]\nurl = "http://mine"\n' > .codex/config.toml
    : > "${WORK}/claude.log"
    out="$(PATH="$BIN_PATH" bash "$INSTALL" mcp --servers playwright,jetbrains --agents claude,codex,opencode,junie)" \
        || fail "mcp(local): non-zero exit"
    [ ! -s "${WORK}/claude.log" ] || fail "mcp(local): called the claude CLI"
    jq -e '.mcpServers.jetbrains == {"type":"http","url":"http://127.0.0.1:9/stream"}
           and .mcpServers.playwright == {"type":"stdio","command":"npx","args":["-y","@playwright/mcp@latest"]}
           and .mcpServers.mine.url == "http://mine" and ."$schema" == "keep-me"' .mcp.json >/dev/null \
        || fail "mcp(local): .mcp.json entries wrong or other content lost"
    grep -q '^model = "o3"$' .codex/config.toml && grep -q '^url = "http://127.0.0.1:9/stream"$' .codex/config.toml \
        && grep -q '^\[mcp_servers.playwright\]$' .codex/config.toml || fail "mcp(local): Codex project config wrong"
    jq -e '.mcp.jetbrains.type == "remote" and .mcp.playwright.type == "local"' opencode.json >/dev/null \
        || fail "mcp(local): opencode.json wrong"
    jq -e '.mcpServers.playwright.command == "npx" and .mcpServers.jetbrains == null' .junie/mcp/mcp.json >/dev/null \
        || fail "mcp(local): Junie project config wrong"
    case "$out" in *"approve the servers in .mcp.json"*) ;; *) fail "mcp(local): no note about approving .mcp.json" ;; esac
    case "$out" in *"trust this folder"*) ;; *) fail "mcp(local): no note about trusting the Codex project" ;; esac
    case "$out" in *"[JetBrains MCP]"*"[Playwright MCP]"*) ;; *) fail "mcp(local): servers not run in the documented order" ;; esac
    cp .mcp.json "${WORK}/l1"; cp .codex/config.toml "${WORK}/l2"; cp opencode.json "${WORK}/l3"
    out="$(PATH="$BIN_PATH" bash "$INSTALL" mcp --servers jetbrains,playwright --agents claude,codex,opencode,junie)" \
        || fail "mcp(local): re-run non-zero exit"
    cmp -s .mcp.json "${WORK}/l1" && cmp -s .codex/config.toml "${WORK}/l2" && cmp -s opencode.json "${WORK}/l3" \
        || fail "mcp(local): re-run changed a file"
    case "$out" in *"Updated: "*|*"Created: "*) fail "mcp(local): re-run reported a change" ;; esac
    pass "mcp writes the project files of every agent by default, without any CLI"

    # Context7 follows the scope: the key goes into the project files, which
    # end up private, and the step says to keep them out of version control.
    rm -rf .junie
    out="$(PATH="$BIN_PATH" bash "$INSTALL" mcp --servers context7 --agents claude,codex,opencode,junie --context7-key ctx7sk-TESTKEY 2>&1)" \
        || fail "mcp-context7(local): non-zero exit"
    case "$out" in *TESTKEY*) fail "mcp-context7(local): the key was printed" ;; esac
    case "$out" in *"keep these files out of version control"*) ;; *) fail "mcp-context7(local): no warning about the key in project files" ;; esac
    jq -e '.mcpServers.context7 == {"type":"http","url":"https://mcp.context7.com/mcp","headers":{"Authorization":"Bearer ctx7sk-TESTKEY"}}' \
        .mcp.json >/dev/null || fail "mcp-context7(local): .mcp.json entry wrong"
    grep -qF 'http_headers = { Authorization = "Bearer ctx7sk-TESTKEY" }' .codex/config.toml || fail "mcp-context7(local): Codex entry wrong"
    jq -e '.mcp.context7.headers.Authorization == "Bearer ctx7sk-TESTKEY"' opencode.json >/dev/null \
        || fail "mcp-context7(local): OpenCode entry wrong"
    jq -e '.mcpServers.context7.env.CONTEXT7_API_KEY == "ctx7sk-TESTKEY"' .junie/mcp/mcp.json >/dev/null \
        || fail "mcp-context7(local): Junie entry wrong"
    for f in .mcp.json .codex/config.toml opencode.json .junie/mcp/mcp.json; do
        [ "$(file_mode "$f")" = 600 ] || fail "mcp-context7(local): ${f} holds the key but is not 0600"
    done
    pass "mcp-context7 at local scope writes the key into private project files and warns"

    # Codex merges the user config into the project: one with the other
    # transport fails a local registration, and neither file changes.
    cp "$USER_CODEX" "${WORK}/u-before"
    printf '[mcp_servers.playwright]\nurl = "http://user"\n' > "$USER_CODEX"
    cp "$USER_CODEX" "${WORK}/u-conflict"; cp .codex/config.toml "${WORK}/l2"
    if out="$(PATH="$BIN_PATH" bash "$INSTALL" playwright --agents codex 2>&1)"; then
        fail "codex(local): a user table with another transport should fail the step"
    fi
    case "$out" in *"${USER_CODEX} defines [mcp_servers.playwright] with another transport"*) ;; *) fail "codex(local): the conflict does not name the user config" ;; esac
    cmp -s "$USER_CODEX" "${WORK}/u-conflict" && cmp -s .codex/config.toml "${WORK}/l2" \
        || fail "codex(local): the refused step changed a Codex config"
    cp "${WORK}/u-before" "$USER_CODEX"
    pass "Codex local registration refuses a user table with another transport"

    # 5t. mcp: --servers is required and checked; "skip" leaves Context7 out;
    #     each option belongs to its steps.
    if bash "$INSTALL" mcp --agents codex >/dev/null 2>&1; then fail "mcp: --servers should be required"; fi
    if bash "$INSTALL" mcp --servers jetbrains,bogus --agents codex >/dev/null 2>&1; then fail "mcp: an unknown server should fail"; fi
    cp .codex/config.toml "${WORK}/l2"; cp "$USER_CODEX" "${WORK}/u-before"
    out="$(bash "$INSTALL" mcp --servers context7 --agents codex --context7-key skip 2>&1)" || fail "mcp: skip should not fail"
    case "$out" in *"[Context7 MCP] Skipped"*) ;; *) fail "mcp: no note that Context7 was skipped" ;; esac
    cmp -s .codex/config.toml "${WORK}/l2" && cmp -s "$USER_CODEX" "${WORK}/u-before" || fail "mcp: skip still wrote a config"
    out="$(bash "$INSTALL" mcp --servers Context7 --agents CODEX --scope LOCAL --context7-key skip 2>&1)" \
        && case "$out" in *"[Context7 MCP] Skipped"*) true ;; *) false ;; esac || fail "mcp: values should be case-insensitive"
    if bash "$INSTALL" mcp-jetbrains --agents codex --servers jetbrains >/dev/null 2>&1; then fail "mcp-jetbrains: --servers is for mcp only"; fi
    if bash "$INSTALL" playwright --agents codex --context7-key x >/dev/null 2>&1; then fail "playwright: --context7-key is for Context7 only"; fi
    cd "$MCP_PROJ"
    rm -rf "$LOCAL_PROJ"
    pass "mcp checks --servers, skips Context7 on 'skip' and keeps options to their steps"

    # 5u. Every Studio command runs: the placeholders filled in as Studio
    #     would, each against this checkout.
    STUDIO_PROJ="${WORK}/studio-project"
    mkdir -p "$STUDIO_PROJ/.git"
    cd "$STUDIO_PROJ"
    STUDIO_META="${SOURCE}/.studio/studio-meta-data.json"
    # Each input gets its Studio default: the default choices, or the default text.
    studio_sed="$(jq -r '.["install-flow"].steps[].inputs[]
        | "s/[$]{\(.id)}/" + (if .type == "options" then ([.choices[] | select(.default) | .value] | join(",")) else .default end) + "/g"' "$STUDIO_META")"
    while IFS= read -r cmd; do
        args="$(printf '%s' "${cmd#*bash -s -- }" | sed -e 's/\${guidelinesBranch}/v3/g' -e "$studio_sed")"
        case "$args" in *'${'*) fail "studio: unknown placeholder in: ${args}" ;; esac
        eval "set -- $args"
        PATH="$BIN_PATH" bash "$INSTALL" "$@" --source "$SOURCE" >/dev/null || fail "studio: command failed: ${args}"
    done <<STUDIO
$(jq -r '.["install-flow"].steps[].command.macos' "$STUDIO_META")
STUDIO
    for f in .agents/skills .claude/skills AGENTS.md CLAUDE.md .mcp.json .codex/config.toml opencode.json .junie/mcp/mcp.json; do
        [ -e "$f" ] || fail "studio: the default commands did not create ${f}"
    done
    jq -e '[.["install-flow"].steps[].command | .linux == .macos] | all' "$STUDIO_META" >/dev/null \
        || fail "studio: a Linux command differs from the macOS one"
    jq -e '.["install-flow"].steps[].inputs[] | select(.id == "context7Key") | .regex as $r
        | (["skip", "ctx7sk-abcdefgh"] | all(test($r))) and (["", "skipx", "short", "bad key", "a\"b-cdefgh"] | any(test($r)) | not)' \
        "$STUDIO_META" >/dev/null || fail "studio: the context7Key regex accepts or rejects the wrong keys"
    cd "$MCP_PROJ"
    rm -rf "$STUDIO_PROJ"
    pass "every Studio command runs against this installer"

    # 5w. The wizard reads its answers from /dev/tty, so it runs on a pty.
    #     The MCP scope defaults to the skills scope, and an empty Context7 key
    #     skips Context7.
    run_wizard() {
        python3 - "$INSTALL" "$SOURCE" "$1" <<'PY'
import os, pty, signal, sys
signal.alarm(120)
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", sys.argv[1], "--source", sys.argv[2]])
os.write(fd, sys.argv[3].encode())
out = b""
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
sys.stdout.write(out.decode(errors="replace"))
sys.exit(os.WEXITSTATUS(os.waitpid(pid, 0)[1]))
PY
    }
    if command -v python3 >/dev/null 2>&1; then
        WIZ_PROJ="${WORK}/wizard-project"
        WIZ_HOME="${WORK}/wizard-home"
        mkdir -p "$WIZ_PROJ/.git" "$WIZ_HOME"
        cd "$WIZ_PROJ"
        out="$(HOME="$WIZ_HOME" PATH="$BIN_PATH" run_wizard $'1\nl\ns\n2,3\n2\n\n\n')" || fail "wizard: non-zero exit"
        case "$out" in *"[Context7 MCP] Skipped"*) ;; *) fail "wizard: an empty key did not skip Context7" ;; esac
        case "$out" in *"MCP:         context7 playwright for codex (local)"*) ;; *) fail "wizard: wrong summary" ;; esac
        [ -e .agents/skills ] && [ ! -e .claude/skills ] && [ ! -e AGENTS.md ] || fail "wizard: skills or guidelines not as chosen"
        grep -q '^\[mcp_servers.playwright\]' .codex/config.toml && ! grep -q context7 .codex/config.toml \
            || fail "wizard: local Codex config not as chosen"
        # Global skills make global the default MCP scope.
        out="$(HOME="$WIZ_HOME" PATH="$BIN_PATH" run_wizard $'1\ng\ns\n3\n3\n\n')" || fail "wizard(global): non-zero exit"
        jq -e '.mcp.playwright' "$WIZ_HOME/.config/opencode/opencode.json" >/dev/null && [ ! -e opencode.json ] \
            || fail "wizard: the MCP scope did not default to the global skills scope"
        cd "$MCP_PROJ"
        rm -rf "$WIZ_PROJ" "$WIZ_HOME"
        pass "the wizard installs what was chosen, at the skills scope by default"
    else
        echo "skip: python3 not found, skipping the wizard test"
    fi

    # 5v. The Context7 key is private before it is written, also through a
    #     symlinked config; checking project configs stages nothing there.
    SAVED_HOME="$HOME"
    export HOME="${WORK}/safe-home"
    mkdir -p "${WORK}/safe-bin" "$HOME/.config/opencode"
    JMIX_REAL_MV="$(command -v mv)"
    JMIX_REAL_CAT="$(command -v cat)"
    export JMIX_REAL_MV JMIX_REAL_CAT
    export JMIX_PRIVATE_TARGET="$HOME/.config/opencode/opencode.json"
    cat > "${WORK}/safe-bin/mv" <<'SH'
#!/bin/bash
if grep -q ctx7sk-TESTKEY "$1"; then
    mode="$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1")"
    [ "$mode" = 600 ] || exit 88
fi
exec "$JMIX_REAL_MV" "$@"
SH
    cat > "${WORK}/safe-bin/cat" <<'SH'
#!/bin/bash
mode="$(stat -L -c '%a' "$JMIX_PRIVATE_TARGET" 2>/dev/null || stat -L -f '%Lp' "$JMIX_PRIVATE_TARGET")"
[ "$mode" = 600 ] || exit 88
exec "$JMIX_REAL_CAT" "$@"
SH
    chmod +x "${WORK}/safe-bin/mv" "${WORK}/safe-bin/cat"
    printf '{}\n' > "$JMIX_PRIVATE_TARGET"
    chmod 644 "$JMIX_PRIVATE_TARGET"
    PATH="${WORK}/safe-bin:$PATH" bash "$INSTALL" mcp-context7 --scope global --agents opencode --context7-key ctx7sk-TESTKEY >/dev/null \
        || fail "mcp-context7: staged key was not private before rename"
    mv "$JMIX_PRIVATE_TARGET" "${WORK}/private-target.json"
    ln -s "${WORK}/private-target.json" "$JMIX_PRIVATE_TARGET"
    printf '{}\n' > "$JMIX_PRIVATE_TARGET"
    chmod 644 "$JMIX_PRIVATE_TARGET"
    PATH="${WORK}/safe-bin:$PATH" bash "$INSTALL" mcp-context7 --scope global --agents opencode --context7-key ctx7sk-TESTKEY >/dev/null \
        || fail "mcp-context7: symlink target was not private before writing"

    JMIX_REAL_AWK="$(command -v awk)"
    JMIX_PROJECT_CONFIG_DIR="$(pwd -P)/.codex"
    export JMIX_REAL_AWK JMIX_PROJECT_CONFIG_DIR
    cat > "${WORK}/safe-bin/awk" <<'SH'
#!/bin/bash
for file in "$JMIX_PROJECT_CONFIG_DIR"/.jmix-mcp.*; do
    [ ! -e "$file" ] || exit 89
done
exec "$JMIX_REAL_AWK" "$@"
SH
    chmod +x "${WORK}/safe-bin/awk"
    mkdir -p .codex
    printf '[mcp_servers.context7]\nurl = "https://mcp.context7.com/mcp"\n' > .codex/config.toml
    chmod 555 .codex
    if ! PATH="${WORK}/safe-bin:$PATH" bash "$INSTALL" mcp-context7 --scope global --agents codex --context7-key ctx7sk-TESTKEY >/dev/null; then
        chmod 755 .codex
        fail "mcp-context7: checking the project config tried to write there"
    fi
    chmod 755 .codex
    ! grep -q TESTKEY .codex/config.toml || fail "mcp-context7: the key landed in the project"
    rm -rf .codex
    pass "the Context7 key is private before writes and never staged in the project"
    export HOME="$SAVED_HOME"
    unset JMIX_REAL_MV JMIX_REAL_CAT JMIX_PRIVATE_TARGET JMIX_REAL_AWK JMIX_PROJECT_CONFIG_DIR
    cd "$PROJECT"
else
    echo "skip: jq not found, skipping MCP assertions"
fi

# ---------------------------------------------------------------------------
# 6. Negative cases
# ---------------------------------------------------------------------------
if bash "$INSTALL" agents-md --source "$SOURCE" >/dev/null 2>&1; then
    fail "negative: agents-md without --conventions should fail"
fi
pass "agents-md without --conventions fails as expected"

if bash "$INSTALL" skills --conventions bogus --scope local --source "$SOURCE" >/dev/null 2>&1; then
    fail "negative: unknown convention should fail"
fi
pass "unknown convention fails as expected"

if bash "$INSTALL" agents-md --agents claude --source "${WORK}/does-not-exist" >/dev/null 2>&1; then
    fail "negative: missing --source dir should fail"
fi
pass "missing --source directory fails as expected"

echo ""
echo "ALL BASH INSTALLER TESTS PASSED"
