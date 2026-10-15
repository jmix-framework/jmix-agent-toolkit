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
bash "$INSTALL" agents-md --agents junie --source "$SOURCE" >/dev/null
cmp -s "${PROJECT}/AGENTS.md" "$BLOCK" || fail "agents-md: Junie's block not written to the root AGENTS.md"
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
[ "$(grep -o -- '--content-ref' "${SOURCE}/.studio/studio-meta-data.json" | wc -l | tr -d ' ')" -eq 10 ] \
    || fail "studio metadata: a macOS/Linux command omits --content-ref"
[ "$(grep -o -- '-ContentRef' "${SOURCE}/.studio/studio-meta-data.json" | wc -l | tr -d ' ')" -eq 5 ] \
    || fail "studio metadata: a Windows command omits -ContentRef"
pass "Studio commands pass the resolved content ref"

# ---------------------------------------------------------------------------
# 5. MCP servers. Files are merged in place, no agent CLI needed (the
#    assertions use jq).
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
    MCP_PROJ="${WORK}/mcp-project"
    mkdir -p "$MCP_PROJ" "${WORK}/bin"
    cd "$MCP_PROJ"
    # Fake agent CLIs. Local scope must not call them; Claude at user scope goes
    # through `claude mcp add`, whose arguments the fake records (and echoes,
    # like the real one does).
    printf '#!/bin/sh\necho "$*" >> "%s/claude.log"\necho "added: $*"\n' "$WORK" > "${WORK}/bin/claude"
    printf '#!/bin/sh\necho called >> "%s/codex.log"\nexit 99\n' "$WORK" > "${WORK}/bin/codex"
    chmod +x "${WORK}/bin/claude" "${WORK}/bin/codex"
    BIN_PATH="${WORK}/bin:${PATH}"
    case "$(uname -s)" in
        Darwin) DESKTOP_DIR="${HOME}/Library/Application Support/Claude" ;;
        *)      DESKTOP_DIR="${HOME}/.config/Claude" ;;
    esac

    # 5a. Local scope, IDE MCP server not reachable -> Streamable HTTP (/stream).
    #     Foreign servers and keys survive; an old [mcp_servers.jetbrains] table
    #     and its sub-table are replaced.
    printf '{\n  "$schema": "keep-me",\n  "mcpServers": {"mine": {"type": "http", "url": "http://mine"}}\n}\n' > .mcp.json
    mkdir -p .codex
    printf 'model = "o3"\n\n[mcp_servers.jetbrains]\ncommand = "java"\n\n[mcp_servers.jetbrains.env]\nIJ_MCP_SERVER_PORT = "64342"\n\n[mcp_servers.mine]\nurl = "http://mine"\n' \
        > .codex/config.toml
    PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --agents claude,codex,opencode,junie --scope local >/dev/null \
        || fail "mcp-jetbrains(local): non-zero exit"
    [ ! -e "${WORK}/claude.log" ] && [ ! -e "${WORK}/codex.log" ] || fail "mcp-jetbrains(local): called an agent CLI"
    jq -e '.mcpServers.jetbrains == {"type":"http","url":"http://127.0.0.1:9/stream"}
           and .mcpServers.mine.url == "http://mine" and ."$schema" == "keep-me"' .mcp.json >/dev/null \
        || fail "mcp-jetbrains(local): .mcp.json entry wrong or other content lost"
    grep -q '^model = "o3"$' .codex/config.toml && grep -q '^\[mcp_servers.mine\]$' .codex/config.toml \
        || fail "mcp-jetbrains(local): other Codex config lost"
    [ "$(grep -c '^\[mcp_servers.jetbrains' .codex/config.toml)" -eq 1 ] \
        && ! grep -q 'IJ_MCP_SERVER_PORT' .codex/config.toml \
        || fail "mcp-jetbrains(local): old Codex jetbrains table not replaced"
    grep -q '^url = "http://127.0.0.1:9/stream"$' .codex/config.toml || fail "mcp-jetbrains(local): Codex url missing"
    jq -e '.mcp.jetbrains == {"type":"remote","url":"http://127.0.0.1:9/stream","enabled":true}' opencode.json >/dev/null \
        || fail "mcp-jetbrains(local): opencode entry wrong"
    [ ! -e .junie/mcp/mcp.json ] || fail "mcp-jetbrains(local): Junie got a JetBrains MCP entry it does not need"
    pass "mcp-jetbrains(local) merges the project files without any agent CLI"

    # 5b. A re-run changes nothing.
    cp .mcp.json "${WORK}/m1"; cp .codex/config.toml "${WORK}/c1"; cp opencode.json "${WORK}/o1"
    PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --agents claude,codex,opencode --scope local >/dev/null \
        || fail "mcp-jetbrains(local): re-run non-zero exit"
    cmp -s .mcp.json "${WORK}/m1" && cmp -s .codex/config.toml "${WORK}/c1" && cmp -s opencode.json "${WORK}/o1" \
        || fail "mcp-jetbrains(local): re-run changed a file"
    pass "mcp-jetbrains(local) re-run leaves the files unchanged"

    # 5c. A file the merge cannot parse (JSONC) is left alone and the step fails;
    #     the other agents are still configured.
    printf '{\n  // mine\n  "theme": "dark"\n}\n' > opencode.json
    cp opencode.json "${WORK}/o2"
    rm -f .mcp.json
    if PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --agents opencode,claude >/dev/null 2>&1; then
        fail "mcp-jetbrains: a JSONC opencode.json should fail the step"
    fi
    cmp -s opencode.json "${WORK}/o2" || fail "mcp-jetbrains: JSONC opencode.json was modified"
    [ -f .mcp.json ] || fail "mcp-jetbrains: a failed agent stopped the agents after it"
    rm -f opencode.json
    pass "mcp-jetbrains leaves an unparsable opencode.json untouched, fails, and continues"

    # 5d. A server defined inline (not as a [table]) is refused, not duplicated.
    printf '[mcp_servers]\njetbrains = { url = "http://mine" }\n' > .codex/config.toml
    cp .codex/config.toml "${WORK}/c2"
    if PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --agents codex >/dev/null 2>&1; then
        fail "mcp-jetbrains: an inline Codex jetbrains entry should fail the step"
    fi
    cmp -s .codex/config.toml "${WORK}/c2" || fail "mcp-jetbrains: inline Codex entry was modified"
    rm -rf .codex
    pass "mcp-jetbrains refuses to touch an inline Codex jetbrains entry"

    # 5e. IntelliJ IDEA before 2026.1 answers 404 on /stream: SSE for Claude and
    #     OpenCode, a stdio bridge for Codex (no SSE transport there).
    if command -v python3 >/dev/null 2>&1; then
        python3 - "${WORK}/port" <<'PY' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(404); self.end_headers()
    do_GET = do_HEAD
    def log_message(self, *args):
        pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_port))
s.serve_forever()
PY
        server_pid=$!
        disown "$server_pid"   # no job-status noise when it is killed below
        # A cold python3 start on a CI macOS runner can take several seconds.
        waited=0
        while [ ! -s "${WORK}/port" ] && [ "$waited" -lt 60 ]; do sleep 0.5; waited=$((waited + 1)); done
        [ -s "${WORK}/port" ] || fail "mcp-jetbrains(sse): the fake IDE server did not start within 30 s"
        port="$(cat "${WORK}/port")"
        rm -f .mcp.json opencode.json
        JMIX_IDE_MCP_PORT="$port" PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --agents claude,codex,opencode >/dev/null \
            || fail "mcp-jetbrains(sse): non-zero exit"
        kill "$server_pid" 2>/dev/null || true
        jq -e --arg u "http://127.0.0.1:${port}/sse" '.mcpServers.jetbrains == {"type":"sse","url":$u}' .mcp.json >/dev/null \
            || fail "mcp-jetbrains(sse): Claude entry is not SSE"
        grep -q "^args = \[\"-y\", \"mcp-remote\", \"http://127.0.0.1:${port}/sse\", \"--transport\", \"sse-only\"\]$" .codex/config.toml \
            || fail "mcp-jetbrains(sse): Codex has no mcp-remote bridge"
        jq -e --arg u "http://127.0.0.1:${port}/sse" '.mcp.jetbrains.url == $u' opencode.json >/dev/null \
            || fail "mcp-jetbrains(sse): OpenCode entry is not SSE"
        rm -rf .mcp.json opencode.json .codex
        pass "mcp-jetbrains falls back to SSE (and a Codex bridge) on IntelliJ IDEA before 2026.1"
    else
        echo "skip: python3 not found, skipping the SSE fallback test"
    fi

    # 5f. Claude Desktop: skipped while it has no config folder, otherwise its
    #     own settings are kept.
    out="$(PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --agents claude-desktop 2>&1)" \
        || fail "mcp-jetbrains: missing Claude Desktop should be a skip, not a failure"
    case "$out" in *"Skipped: Claude Desktop"*) ;; *) fail "mcp-jetbrains: no skip message for Claude Desktop" ;; esac
    mkdir -p "$DESKTOP_DIR"
    printf '{"preferences": {"keep": true}}' > "${DESKTOP_DIR}/claude_desktop_config.json"
    PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --agents claude-desktop >/dev/null \
        || fail "mcp-jetbrains(desktop): non-zero exit"
    jq -e '.preferences.keep == true and .mcpServers.jetbrains.command == "npx"
           and (.mcpServers.jetbrains.args | index("mcp-remote"))' "${DESKTOP_DIR}/claude_desktop_config.json" >/dev/null \
        || fail "mcp-jetbrains(desktop): bridge entry missing or preferences lost"
    pass "mcp-jetbrains configures Claude Desktop through a stdio bridge"

    # 5g. Context7 is always user level; the key never reaches the output or
    #     the project, and the user files holding it are private.
    out="$(PATH="$BIN_PATH" bash "$INSTALL" mcp-context7 --agents claude,codex,opencode,junie,claude-desktop \
        --context7-key ctx7sk-TESTKEY 2>&1)" || fail "mcp-context7: non-zero exit"
    case "$out" in *TESTKEY*) fail "mcp-context7: the API key was printed" ;; esac
    grep -qF -- '--scope user --transport http context7 https://mcp.context7.com/mcp --header Authorization: Bearer ctx7sk-TESTKEY' \
        "${WORK}/claude.log" || fail "mcp-context7: wrong claude mcp add arguments"
    grep -qF 'http_headers = { Authorization = "Bearer ctx7sk-TESTKEY" }' "${HOME}/.codex/config.toml" \
        || fail "mcp-context7: Codex user config entry wrong"
    jq -e '.mcp.context7.headers.Authorization == "Bearer ctx7sk-TESTKEY"' "${HOME}/.config/opencode/opencode.json" >/dev/null \
        || fail "mcp-context7: OpenCode user config entry wrong"
    jq -e '.mcpServers.context7.env.CONTEXT7_API_KEY == "ctx7sk-TESTKEY"' "${HOME}/.junie/mcp/mcp.json" >/dev/null \
        || fail "mcp-context7: Junie user config entry wrong"
    jq -e '.mcpServers.context7.env.CONTEXT7_API_KEY == "ctx7sk-TESTKEY" and .preferences.keep == true' \
        "${DESKTOP_DIR}/claude_desktop_config.json" >/dev/null || fail "mcp-context7: Claude Desktop entry wrong"
    ! grep -rq TESTKEY "$MCP_PROJ" || fail "mcp-context7: the API key landed in the project"
    for f in "${HOME}/.codex/config.toml" "${HOME}/.config/opencode/opencode.json" "${HOME}/.junie/mcp/mcp.json"; do
        [ "$(file_mode "$f")" = 600 ] || fail "mcp-context7: ${f} holds the key but is not 0600"
    done
    if bash "$INSTALL" mcp-context7 --agents codex --context7-key 'bad"key' >/dev/null 2>&1; then
        fail "mcp-context7: a key with a quote should be rejected"
    fi
    pass "mcp-context7 registers every agent at user level without printing the key"

    # 5h. Playwright MCP, local scope; links and store of the old playwright-cli
    #     skill go away, foreign skills stay.
    mkdir -p "${HOME}/.agents/.playwright/skills/playwright-cli" "${HOME}/.claude/skills/my-skill"
    ln -s ../../.agents/.playwright/skills/playwright-cli "${HOME}/.claude/skills/playwright-cli"
    PATH="$BIN_PATH" bash "$INSTALL" playwright --agents claude,codex,opencode,junie --scope local >/dev/null \
        || fail "playwright(local): non-zero exit"
    jq -e '.mcpServers.playwright == {"type":"stdio","command":"npx","args":["-y","@playwright/mcp@latest"]}' .mcp.json >/dev/null \
        || fail "playwright(local): Claude entry wrong"
    grep -q '^args = \["-y", "@playwright/mcp@latest"\]$' .codex/config.toml || fail "playwright(local): Codex entry wrong"
    jq -e '.mcp.playwright.command == ["npx","-y","@playwright/mcp@latest"]' opencode.json >/dev/null \
        || fail "playwright(local): OpenCode entry wrong"
    jq -e '.mcpServers.playwright.args == ["-y","@playwright/mcp@latest"]' .junie/mcp/mcp.json >/dev/null \
        || fail "playwright(local): Junie entry wrong"
    [ ! -e "${HOME}/.claude/skills/playwright-cli" ] && [ ! -L "${HOME}/.claude/skills/playwright-cli" ] \
        && [ ! -e "${HOME}/.agents/.playwright" ] || fail "playwright: old playwright-cli skill not removed"
    [ -d "${HOME}/.claude/skills/my-skill" ] || fail "playwright: removed a foreign skill"
    pass "playwright registers the MCP server locally and removes the old CLI skill"

    PATH="$BIN_PATH" bash "$INSTALL" playwright --agents claude --scope global >/dev/null \
        || fail "playwright(global): non-zero exit"
    grep -qF -- '--scope user playwright -- npx -y @playwright/mcp@latest' "${WORK}/claude.log" \
        || fail "playwright(global): wrong claude mcp add arguments"
    out="$(PATH=/usr/bin:/bin bash "$INSTALL" playwright --agents claude --scope global 2>&1)" \
        || fail "playwright(global): a missing claude CLI should be a skip, not a failure"
    case "$out" in *"Skipped: 'claude' CLI not found"*) ;; *) fail "playwright(global): no skip message" ;; esac
    pass "playwright(global) goes through the claude CLI and skips without it"

    if bash "$INSTALL" playwright --agents codex --scope nowhere >/dev/null 2>&1; then
        fail "playwright: an invalid --scope should fail"
    fi
    pass "playwright rejects an invalid --scope"

    # 5i. Codex merges the user and project tables key by key and refuses a
    #     url+command mix: the other layer is brought to the same transport.
    rm -rf .codex
    printf '[mcp_servers.jetbrains]\ncommand = "java"\nargs = ["-cp", "x"]\n' > "${HOME}/.codex/config.toml.jb"
    cat "${HOME}/.codex/config.toml" >> "${HOME}/.codex/config.toml.jb"
    mv "${HOME}/.codex/config.toml.jb" "${HOME}/.codex/config.toml"
    PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --agents codex --scope local >/dev/null \
        || fail "mcp-jetbrains: non-zero exit with a stdio jetbrains entry at user level"
    awk '/^\[mcp_servers.jetbrains\]/{f=1;next} /^\[/{f=0} f' "${HOME}/.codex/config.toml" > "${WORK}/jb-user"
    grep -q '^url = "http://127.0.0.1:9/stream"$' "${WORK}/jb-user" && ! grep -q '^command' "${WORK}/jb-user" \
        || fail "mcp-jetbrains: user-level Codex jetbrains not aligned with the project's transport"
    grep -q 'Authorization = "Bearer ctx7sk-TESTKEY"' "${HOME}/.codex/config.toml" \
        || fail "mcp-jetbrains: aligning the user layer lost its other servers"
    pass "mcp-jetbrains aligns the transport of the other Codex layer"

    printf '[mcp_servers.context7]\ncommand = "npx"\n' > .codex/config.toml
    if bash "$INSTALL" mcp-context7 --agents codex --context7-key ctx7sk-TESTKEY >/dev/null 2>&1; then
        fail "mcp-context7: a project stdio context7 next to the user url entry should fail the step"
    fi
    ! grep -q TESTKEY .codex/config.toml || fail "mcp-context7: the key was written into the project"
    rm -rf .codex
    pass "mcp-context7 refuses to align a project table with the key"

    # 5j. A table is replaced where it stands: the order and the comment that
    #     introduces the next table stay, and alternating steps converge.
    mkdir -p .codex
    printf '[mcp_servers.jetbrains]\nurl = "old"\n\n# my own server\n[mcp_servers.mine]\nurl = "http://mine"\n' > .codex/config.toml
    PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --agents codex >/dev/null || fail "toml: non-zero exit"
    [ "$(sed -n 1p .codex/config.toml)" = '[mcp_servers.jetbrains]' ] || fail "toml: replaced table moved"
    grep -q '^# my own server$' .codex/config.toml || fail "toml: comment before the next table lost"
    PATH="$BIN_PATH" bash "$INSTALL" playwright --agents codex >/dev/null || fail "toml: playwright non-zero exit"
    cp .codex/config.toml "${WORK}/c3"
    out="$(PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --agents codex; PATH="$BIN_PATH" bash "$INSTALL" playwright --agents codex)"
    cmp -s .codex/config.toml "${WORK}/c3" || fail "toml: alternating steps keep rewriting config.toml"
    case "$out" in *"Updated: "*) fail "toml: an unchanged config.toml was reported as updated" ;; esac
    pass "toml tables are replaced in place and re-runs converge"

    # 5k. A root inline mcp_servers table is refused; a BOM before the first
    #     header does not duplicate the table.
    printf 'mcp_servers = { jetbrains = { url = "x" } }\n' > .codex/config.toml
    cp .codex/config.toml "${WORK}/c4"
    if PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --agents codex >/dev/null 2>&1; then
        fail "toml: a root inline mcp_servers table should fail the step"
    fi
    cmp -s .codex/config.toml "${WORK}/c4" || fail "toml: root inline table was modified"
    printf '\357\273\277[mcp_servers.jetbrains]\nurl = "old"\n' > .codex/config.toml
    PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --agents codex >/dev/null || fail "toml: BOM file non-zero exit"
    [ "$(grep -c 'mcp_servers.jetbrains' .codex/config.toml)" -eq 1 ] || fail "toml: BOM header duplicated the table"
    [ "$(head -c 3 .codex/config.toml)" = $'\xef\xbb\xbf' ] || fail "toml: leading BOM lost"
    rm -rf .codex
    pass "toml refuses inline definitions and handles a leading BOM"

    # 5l. An unreadable config is reported and kept, never replaced.
    if [ "$(id -u)" != 0 ]; then
        printf '{"mcpServers": {"mine": {"command": "keep-me"}}}' > .mcp.json
        chmod 000 .mcp.json
        if PATH="$BIN_PATH" bash "$INSTALL" playwright --agents claude >/dev/null 2>&1; then
            fail "json: an unreadable .mcp.json should fail the step"
        fi
        chmod 644 .mcp.json
        grep -q keep-me .mcp.json || fail "json: an unreadable .mcp.json was replaced"
        rm -f .mcp.json
        pass "an unreadable config is kept and fails the step"
    fi

    # 5m. Without jq and node a new JSON config is still created (no merge
    #     needed), and a re-run finds it unchanged.
    mkdir -p "${WORK}/minbin"
    for tool in awk sed grep mktemp cmp chmod mv cat dirname basename head tail tr rm mkdir uname cut stat cp ln readlink id; do
        p="$(command -v "$tool" 2>/dev/null)" && ln -sf "$p" "${WORK}/minbin/${tool}"
    done
    mkdir -p "${WORK}/nojq" && cd "${WORK}/nojq"
    PATH="${WORK}/minbin" /bin/bash "$INSTALL" mcp-jetbrains --agents claude,opencode >/dev/null \
        || fail "json: creating configs without jq/node failed"
    jq -e '.mcpServers.jetbrains.url == "http://127.0.0.1:9/stream"' .mcp.json >/dev/null \
        && jq -e '.mcp.jetbrains.type == "remote"' opencode.json >/dev/null || fail "json: configs created without jq/node are wrong"
    out="$(PATH="${WORK}/minbin" /bin/bash "$INSTALL" mcp-jetbrains --agents claude,opencode)" \
        || fail "json: re-run without jq/node failed"
    case "$out" in *"Updated: "*|*"Created: "*) fail "json: re-run without jq/node rewrote a config" ;; esac
    cd "$MCP_PROJ"
    pass "JSON configs are created and re-checked without jq or node"

    # 5n. An existing user config that gets the Context7 key ends up private.
    chmod 644 "${HOME}/.config/opencode/opencode.json"
    bash "$INSTALL" mcp-context7 --agents opencode --context7-key ctx7sk-TESTKEY >/dev/null || fail "mcp-context7: re-run failed"
    [ "$(file_mode "${HOME}/.config/opencode/opencode.json")" = 600 ] \
        || fail "mcp-context7: a 0644 opencode.json kept its mode after getting the key"
    pass "mcp-context7 makes an existing user config private"

    # 5o. The old-store cleanup leaves other links alone and does not stop
    #     the step when the store cannot be removed.
    mkdir -p "${HOME}/.agents/.playwright/skills/playwright-cli" "${WORK}/x.playwright/skills/mine"
    ln -s "${WORK}/x.playwright/skills/mine" "${HOME}/.claude/skills/mine"
    if [ "$(id -u)" != 0 ]; then
        touch "${HOME}/.agents/.playwright/skills/playwright-cli/SKILL.md"
        chmod 555 "${HOME}/.agents/.playwright/skills/playwright-cli"
    fi
    PATH="$BIN_PATH" bash "$INSTALL" playwright --agents junie >/dev/null 2>&1 \
        || fail "playwright: an unremovable old store stopped the step"
    [ -L "${HOME}/.claude/skills/mine" ] || fail "playwright: removed a link that is not into the old store"
    chmod -R u+w "${HOME}/.agents/.playwright" 2>/dev/null || true
    rm -rf "${HOME}/.agents/.playwright" "${HOME}/.claude/skills/mine"
    pass "playwright cleanup touches only links into the old store and never blocks"

    # 5p. Misc: a bad port is refused up front, --source is accepted, and the
    #     Claude Desktop restart reminder appears only when it was written.
    if JMIX_IDE_MCP_PORT='9"x' bash "$INSTALL" mcp-jetbrains --agents codex >/dev/null 2>&1; then
        fail "a JMIX_IDE_MCP_PORT that is not a number should fail"
    fi
    PATH="$BIN_PATH" bash "$INSTALL" mcp-jetbrains --agents codex --source "$SOURCE" >/dev/null \
        || fail "mcp-jetbrains: --source should be accepted"
    rm -rf "$DESKTOP_DIR"
    out="$(PATH="$BIN_PATH" bash "$INSTALL" playwright --agents claude-desktop)"
    case "$out" in *"Quit Claude Desktop"*) fail "restart reminder printed for a skipped Claude Desktop" ;; esac
    pass "port validation, --source and the Claude Desktop reminder"
    cd "$PROJECT"
else
    echo "skip: jq not found, skipping MCP assertions"
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
