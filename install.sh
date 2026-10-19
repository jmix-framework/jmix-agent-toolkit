#!/usr/bin/env bash
# Jmix AI Agents Toolkit installer.
#
# Default (no subcommand) launches an interactive wizard that guides through:
#   1. Installing Jmix skills (globally or into the project) for one or all agents.
#   2. Adding project-level guidelines (CLAUDE.md / AGENTS.md).
#   3. Registering the JetBrains MCP server with the agent.
#   4. Registering the Context7 MCP server with the agent.
#   5. Registering the Playwright MCP server with the agent.
#
# Subcommands are available for non-interactive use; see `install.sh --help`.

set -euo pipefail

REPO_OWNER="jmix-framework"
REPO_NAME="jmix-agent-toolkit"

# Global state populated by ensure_tarball()
STAGING=""
EXTRACTED_DIR=""
SOURCE_SKILLS_DIR=""
SOURCE_GUIDELINES_BLOCK=""
RESOLVED_VERSION_DIR=""
TARBALL_READY=0

# Branch identity: this script lives on the CONTENT_REF branch and installs that
# branch's content/. Set per branch when cutting a new version (see MAINTAINING.md).
CONTENT_REF="v3"
SOURCE_DIR=""
BACKUP_EXISTING=0
VERBOSE=0

ALL_AGENTS="claude codex opencode junie"
# Junie works inside the IDE and needs no JetBrains MCP; the wizard does not offer it.
JETBRAINS_AGENTS="claude codex opencode"

# IntelliJ IDEA's MCP server listens on 127.0.0.1 only. Its default port is
# 64342; another JetBrains IDE started first moves it, hence the override.
JB_PORT="${JMIX_IDE_MCP_PORT:-64342}"
# "stream" (IntelliJ 2026.1+) or "sse" (2025.2/2025.3); see detect_jetbrains_transport.
JB_TRANSPORT="stream"
# 1 when the IDE did not answer and JB_TRANSPORT is only assumed.
JB_GUESSED=0
CONTEXT7_URL="https://mcp.context7.com/mcp"
# 1 while writing entries that carry the Context7 key; see commit_config.
MCP_PRIVATE=0
# 1 when the last commit_config created or updated its file.
CONFIG_CHANGED=0
PLAYWRIGHT_MCP_PKG="@playwright/mcp@latest"

# =================================================================
# Helpers
# =================================================================

log() {
    printf '%s\n' "$*"
}

err() {
    printf 'error: %s\n' "$*" >&2
}

die() {
    err "$*"
    exit 1
}

# Prints a diagnostic line to stderr, only when --verbose/--debug is set.
vlog() {
    [ "$VERBOSE" -eq 1 ] && printf '[debug] %s\n' "$*" >&2
    return 0
}

# Dumps environment + tool versions (verbose only) to help diagnose user issues.
debug_env() {
    [ "$VERBOSE" -eq 1 ] || return 0
    vlog "os: $(uname -a 2>/dev/null)"
    vlog "pwd: $(pwd -P 2>/dev/null)"
    vlog "HOME: ${HOME:-}"
    vlog "PATH: ${PATH:-}"
    vlog "bash: ${BASH_VERSION:-?}"
    vlog "curl: $(command -v curl 2>/dev/null || echo 'not found')"
    vlog "tar: $(command -v tar 2>/dev/null || echo 'not found')"
    vlog "git: $(git --version 2>/dev/null || echo 'not found')"
    vlog "node: $(node --version 2>/dev/null || echo 'not found')"
    vlog "npx: $(npx --version 2>/dev/null || echo 'not found')"
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || die "$1 not found. Install it and re-run."
}

# MCP servers started through npx need Node.js on the machine the agent runs
# on, not at install time, so a missing npx is only a warning.
warn_if_no_npx() {
    command -v npx >/dev/null 2>&1 && return 0
    log ""
    log "Note: $1 starts through npx, which is not on PATH here. Install Node.js 20+ (https://nodejs.org) before using it."
}

# Returns a not-yet-existing backup path for $1: first "<path>.bak", then on
# collision "<path>.bak1", "<path>.bak2", ... so an earlier backup is never
# overwritten. ponytail: linear probe, fine for the handful of backups a
# project accrues.
dedup_backup_path() {
    local base="$1"
    local candidate="${base}.bak"
    local n=1
    while [ -e "$candidate" ]; do
        candidate="${base}.bak${n}"
        n=$((n + 1))
    done
    printf '%s' "$candidate"
}

# Replaces or installs $dest with a copy of $src. An existing $dest is backed up
# (moved aside to a deduped <dest>.bak[N]) when BACKUP_EXISTING=1; otherwise it
# is deleted. Prints a per-item log line.
# $1 - src path (file or dir)
# $2 - dest path
# $3 - short label shown in the log line
write_dest() {
    local src="$1"
    local dest="$2"
    local label="$3"
    local existed=0
    # A dangling dest symlink counts too: cp would write through it.
    { [ -e "$dest" ] || [ -L "$dest" ]; } && existed=1
    local backup_info=""
    if [ "$existed" -eq 1 ]; then
        if [ "$BACKUP_EXISTING" -eq 1 ]; then
            local backup
            backup="$(dedup_backup_path "$dest")"
            mv "$dest" "$backup" || die "cannot rename ${dest}"
            backup_info=" (backup: $(basename "$backup"))"
        else
            rm -rf "$dest" || die "cannot remove ${dest}"
        fi
    fi
    cp -R "$src" "$dest" || die "cannot copy to ${dest}"
    if [ "$existed" -eq 1 ]; then
        log "  Updated: ${label}${backup_info}"
    else
        log "  Installed: ${label}"
    fi
}

# Emits a machine-readable change marker consumed by Jmix Studio's finish step.
# Gated by JMIX_EMIT_CHANGE_MARKERS so manual CLI runs print nothing extra.
# $1 - action (created|updated|backed-up)  $2 - type (file|dir)  $3 - absolute path
emit_change() {
    [ "${JMIX_EMIT_CHANGE_MARKERS:-0}" = "1" ] || return 0
    printf '@@JMIX_CHANGE@@\taction=%s\ttype=%s\tpath=%s\n' "$1" "$2" "$3"
}

# Parses a comma-separated agents list. Single value (e.g. "claude") is allowed.
# Validates each token. Emits a space-separated list to stdout.
# $1 - csv string (may be empty)
# $2 - subcommand name for the error message
# $3 - space-separated valid agents (defaults to ALL_AGENTS)
parse_agents_csv() {
    local csv="$1"
    local subcommand="$2"
    local valid="${3:-$ALL_AGENTS}"
    if [ -z "$csv" ]; then
        die "${subcommand}: --agents is required (e.g. --agents claude,codex)"
    fi
    local result=""
    local token
    for token in $(printf '%s' "$csv" | tr ',' ' ' | tr -s ' ' ' '); do
        case " ${valid} " in
            *" ${token} "*) result="${result} ${token}" ;;
            *) die "${subcommand}: unknown agent in --agents: '$token' (valid: $(printf '%s' "$valid" | tr ' ' ','))" ;;
        esac
    done
    result="$(printf '%s' "$result" | sed 's/^ //;s/ $//')"
    [ -n "$result" ] || die "${subcommand}: --agents resolved to an empty list"
    printf '%s' "$result"
}

# Reads a line from /dev/tty so prompts work under `curl ... | bash`.
# Falls back to the supplied default when no TTY is available.
prompt() {
    local message="$1"
    local default="${2:-}"
    local hint=""
    [ -n "$default" ] && hint=" [${default}]"

    # Subshell with stderr silenced so /dev/tty redirection errors stay quiet
    # in headless environments.
    local answer
    answer="$(
        exec 2>/dev/null
        if printf '%s%s: ' "$message" "$hint" >/dev/tty; then
            local ans=""
            IFS= read -r ans </dev/tty || ans=""
            printf '%s' "$ans"
        fi
    )"

    if [ -z "$answer" ] && [ -n "$default" ]; then
        answer="$default"
    fi
    printf '%s' "$answer"
}

prompt_yes_no() {
    local message="$1"
    local default="${2:-y}"
    local hint="[Y/n]"
    [ "$default" = "n" ] && hint="[y/N]"
    local answer
    answer="$(prompt "$message $hint" "$default")"
    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

usage() {
    cat <<'EOF'
Jmix AI Agents Toolkit installer.

Usage:
  install.sh                                                     # interactive wizard
  install.sh skills        --agents CSV [--scope global|local]   # install skills into the canonical store and symlink agent dirs
  install.sh agents-md     [options]                             # install project guidelines
  install.sh mcp-jetbrains [options]                             # register JetBrains MCP (user level)
  install.sh mcp-context7  [options] [--context7-key KEY]        # register Context7 MCP (user level)
  install.sh playwright    [options]                             # register Playwright MCP (user level)

Common options:
  --content-ref REF          Repository branch/ref to download and use. Defaults
                             to this release branch (v3). Studio passes its
                             resolved toolkit branch here.
  --source DIR               Install from a local checkout of this repository
                             instead of downloading. Skips the network. Mainly
                             for CI and offline use.
  --agents CSV               Comma-separated agent list. Accepts a single value
                             too (e.g. "claude" or "claude,codex"). Required by
                             every subcommand. Valid values:
                             claude, codex, opencode, junie. In the MCP
                             subcommands, claude also sets up Claude Desktop
                             when it is installed here.
  --backup-existing-files    Rename overwritten files/dirs to <name>.bak
                             (deduped: .bak, .bak1, .bak2, ...) instead of
                             deleting them. Off by default. Project guidelines
                             (CLAUDE.md / AGENTS.md) are merged
                             rather than overwritten and are not covered by this
                             flag: a backup is made only when the toolkit
                             rewrites content it does not own -- replacing a
                             guidelines file an older toolkit version installed,
                             or adding the block to your own file. Replacing only the
                             marked region never makes a backup, and a file
                             that is already up to date is left untouched.
  --verbose, --debug         Print extra diagnostic output (OS, PATH, resolved
                             paths, tool versions) to help troubleshoot problems.
  -h, --help                 Show this help.

skills options:
  --scope global|local   Where to install skills. "global" (default) writes to
                         the per-agent user-home dir; "local" writes to the
                         matching dir under the current project (e.g.
                         ./.claude/skills).

mcp-jetbrains / mcp-context7 / playwright:
  MCP servers are registered in each agent's user config, so they serve every
  project; Claude Code's through the claude CLI. Project files are not written.

mcp-context7 options:
  --context7-key K   Context7 API key. Prompted interactively when missing.

Environment:
  JMIX_IDE_MCP_PORT  Port of the IntelliJ IDEA MCP server (default 64342).
EOF
}

# =================================================================
# Tarball download
# =================================================================

# Downloads and extracts the tarball, locates the content/ folder, and populates
# SOURCE_SKILLS_DIR / SOURCE_GUIDELINES_BLOCK / RESOLVED_VERSION_DIR. Idempotent.
ensure_tarball() {
    [ "$TARBALL_READY" -eq 1 ] && return 0

    if [ -n "$SOURCE_DIR" ]; then
        # Install from a local checkout instead of downloading. Skips the network
        # entirely. Used by CI and offline installs.
        [ -d "$SOURCE_DIR" ] || die "source directory not found: ${SOURCE_DIR}"
        EXTRACTED_DIR="$(cd "$SOURCE_DIR" && pwd -P)"
        vlog "using local source dir: ${EXTRACTED_DIR} (download skipped)"
    else
        require_tool curl
        require_tool tar

        STAGING="$(mktemp -d 2>/dev/null || mktemp -d -t jmix-install)"
        trap 'rm -rf "$STAGING"' INT TERM EXIT

        local tarball_path="${STAGING}/source.tar.gz"
        vlog "staging dir: ${STAGING}"

        local tarball_url="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/${CONTENT_REF}"
        log "Downloading ${tarball_url}"
        local http_status
        http_status="$(curl -sSL --retry 3 --retry-delay 2 --connect-timeout 30 --max-time 300 -w '%{http_code}' -o "$tarball_path" "$tarball_url" || echo "000")"
        if [ "$http_status" != "200" ]; then
            die "failed to download ${tarball_url} (HTTP ${http_status})"
        fi

        tar -xzf "$tarball_path" -C "$STAGING"
        EXTRACTED_DIR="$(find "$STAGING" -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -n 1)"
        [ -n "$EXTRACTED_DIR" ] || die "extracted source directory not found in ${STAGING}"
    fi

    local content_dir="${EXTRACTED_DIR}/content"
    if [ ! -d "${content_dir}/skills" ]; then
        die "content/skills not found in ${SOURCE_DIR:-$CONTENT_REF}"
    fi
    SOURCE_SKILLS_DIR="${content_dir}/skills"
    SOURCE_GUIDELINES_BLOCK="${content_dir}/guidelines-block.md"

    # Store segment under ~/.agents/.jmix/skills/<seg>: the branch name, so
    # multiple Jmix majors coexist on one machine.
    RESOLVED_VERSION_DIR="$CONTENT_REF"

    vlog "extracted dir: ${EXTRACTED_DIR}"
    vlog "store segment: ${RESOLVED_VERSION_DIR}"
    vlog "source skills dir: ${SOURCE_SKILLS_DIR}"
    log "Using guidelines from ${SOURCE_SKILLS_DIR#"${EXTRACTED_DIR}"/}"

    TARBALL_READY=1
}

# =================================================================
# skills install (global, per agent)
# =================================================================

# Validates the install scope. Emits the normalized value ("global"/"local").
# $1 - raw scope string   $2 - subcommand name for the error message
parse_scope() {
    case "$1" in
        global|local) printf '%s' "$1" ;;
        *) die "$2: --scope must be 'global' or 'local' (got '$1')" ;;
    esac
}

# Relative skills dir each agent reads, used as a whole-dir symlink to the store.
# claude -> .claude/skills ; codex, opencode & junie -> .agents/skills (open
# standard). Rooted at $HOME (global) or the project dir (local).
agent_symlink_rel() {
    case "$1" in
        claude)               printf '.claude/skills' ;;
        codex|opencode|junie) printf '.agents/skills' ;;
        *) die "unknown agent '$1'" ;;
    esac
}

# Earlier versions also linked the skills into .junie/skills. Junie reads
# .agents/skills now, and its CLI reads ~/.junie/skills first, so links left
# there would shadow newer skills: the toolkit's own links are removed. Only
# when this run linked .agents/skills (otherwise Junie would be left with no
# skills), and never from a .junie/skills that is the same dir as an agent
# skills dir: its links are the ones this run just created.
# $1 - scope root (the user home or the project dir)   $2 - agents of this run
remove_old_junie_skill_links() {
    local dir="$1/.junie/skills" link
    [ -d "$dir" ] || return 0
    case " $2 " in *" codex "*|*" opencode "*|*" junie "*) ;; *) return 0 ;; esac
    if [ "$dir" -ef "$1/.agents/skills" ] || [ "$dir" -ef "$1/.claude/skills" ]; then
        return 0
    fi
    for link in "$dir"/jmix "$dir"/jmix-*; do
        [ -L "$link" ] || continue
        case "$(readlink "$link")" in
            */.agents/.jmix/skills/*|*/.skills/*)
                rm -f "$link" && log "  Removed old Junie skill link ${link}" ;;
        esac
    done
    rmdir "$dir" 2>/dev/null || true
}

# Removes a path only when it is a dangling (broken) symlink, so a later
# `mkdir -p` does not fail with ENOENT on macOS/BSD when a path component points
# at a missing target (e.g. a leftover ~/.junie symlink). A symlink that resolves
# to an existing directory is left untouched.
clear_dangling_symlink() {
    local p="$1"
    [ -L "$p" ] && [ ! -e "$p" ] || return 0
    if [ "$BACKUP_EXISTING" -eq 1 ]; then
        mv "$p" "$(dedup_backup_path "$p")" 2>/dev/null || rm -f "$p"
    else
        rm -f "$p"
    fi
}

# Creates (or refreshes) a whole-dir symlink $1 -> $2. Replaces an existing
# symlink; an existing real dir is backed up (when --backup-existing-files) or
# removed. Requires symlink support; fails otherwise.
create_symlink() {
    local link="$1"
    local target="$2"
    if [ -L "$link" ]; then
        rm -f "$link" || die "cannot replace symlink ${link}"
    elif [ -e "$link" ]; then
        if [ "$BACKUP_EXISTING" -eq 1 ]; then
            mv "$link" "$(dedup_backup_path "$link")" || die "cannot back up ${link}"
        else
            rm -rf "$link" || die "cannot remove ${link}"
        fi
    fi
    mkdir -p "$(dirname "$link")" || die "cannot create parent of ${link}"
    ln -s "$target" "$link" \
        || die "cannot create symlink ${link} -> ${target}. Your filesystem/OS may not permit symlinks."
}

# Copies each source skill folder into the canonical store (overwrite or backup
# via write_dest).
install_skills_to_store() {
    local store_dir="$1"
    log ""
    log "Installing skills into store ${store_dir}"
    mkdir -p "$store_dir" || die "cannot create store ${store_dir}"
    local skill name dest
    for skill in "$SOURCE_SKILLS_DIR"/*/; do
        [ -d "$skill" ] || continue
        name="$(basename "$skill")"
        dest="${store_dir}/${name}"
        write_dest "$skill" "$dest" "$name"
    done
}

relpath() {
    local base="$1" target="$2" up=""
    while [ "$target" != "$base" ] && [ "${target#"$base"/}" = "$target" ]; do
        # Only "/" in common (e.g. ~/.claude -> /mnt/c/...): "${target#//}" never
        # strips, so stop here instead of climbing forever.
        if [ "$base" = / ]; then
            printf '%s%s' "$up" "${target#/}"
            return
        fi
        base="$(dirname "$base")"
        up="../$up"
    done
    if [ "$target" = "$base" ]; then
        printf '%s' "${up:-.}"
    else
        printf '%s%s' "$up" "${target#"$base"/}"
    fi
}

# Creates agent skills dir $1 and prints its physical path. A symlinked dir
# (e.g. ~/.agents/skills -> ~/.claude/skills) must be resolved: a relative link
# target is interpreted where the link physically lives.
prepare_agent_dir() {
    # Clear a broken-symlink agent base/dir (e.g. ~/.junie -> missing) so mkdir works.
    clear_dangling_symlink "$(dirname "$1")"
    clear_dangling_symlink "$1"
    mkdir -p "$1" || die "cannot create $1"
    (cd "$1" && pwd -P)
}

# Per-skill symlinks: link each store skill folder into the agent skills dir,
# so Jmix skills coexist with other skills already present there. The link target
# is relative to the agent dir (see relpath) so links stay valid after a clone.
# Only the skills being installed are linked: the store also keeps the backups
# that --backup-existing-files makes there.
# $1 - physical agent skills dir (kept as a real dir), see prepare_agent_dir
# $2 - store dir holding the skill folders
link_skills_into_dir() {
    local agent_dir="$1"
    local store_dir="$2"
    local rel_store skill name
    rel_store="$(relpath "$agent_dir" "$(cd "$store_dir" && pwd -P)")"
    for skill in "$SOURCE_SKILLS_DIR"/*/; do
        [ -d "$skill" ] || continue
        name="$(basename "$skill")"
        create_symlink "${agent_dir}/${name}" "${rel_store}/${name}"
    done
    # Earlier versions linked those store backups too; their links go.
    for skill in "$agent_dir"/*.bak*; do
        [ -L "$skill" ] || continue
        case "$(readlink "$skill")" in
            "${rel_store}/$(basename "$skill")") rm -f "$skill" ;;
        esac
    done
}

# Links the store into the skills dir of every agent in $3 under root $1.
# Agents sharing a dir (codex/opencode), or dirs resolving to the same physical
# dir, are linked once.
link_store_into_agents() {
    local root="$1" store_dir="$2" agents="$3"
    local agent agent_dir phys existed seen=" "
    for agent in $agents; do
        agent_dir="${root}/$(agent_symlink_rel "$agent")"
        existed=0
        [ -d "$agent_dir" ] && existed=1
        phys="$(prepare_agent_dir "$agent_dir")" || return 1
        case "$seen" in
            *" ${phys} "*) continue ;;
        esac
        seen="${seen}${phys} "
        # An agent dir that is the store (e.g. .claude/skills -> ../.skills)
        # already holds the skills; links there would point at themselves.
        if [ "$phys" -ef "$store_dir" ]; then
            log "  ${agent_dir} is the skills store itself; nothing to link"
            continue
        fi
        link_skills_into_dir "$phys" "$store_dir"
        emit_change "$([ "$existed" -eq 1 ] && printf updated || printf created)" dir "$agent_dir"
        log "  Linked skills into ${agent_dir}"
    done
    remove_old_junie_skill_links "$root" "$agents"
}

agent_label() {
    case "$1" in
        claude)         printf 'Claude CLI' ;;
        codex)          printf 'Codex' ;;
        opencode)       printf 'OpenCode' ;;
        junie)          printf 'Junie' ;;
        *) printf '%s' "$1" ;;
    esac
}

cmd_skills() {
    local agents_csv=""
    local scope="global"

    local _argc=-1
    while [ $# -gt 0 ]; do
        [ "$#" -ne "$_argc" ] || die "argument parser made no progress near: $1"
        _argc=$#
        case "$1" in
            --agents)
                [ $# -ge 2 ] || die "--agents requires an argument"
                agents_csv="$2"; shift 2 ;;
            --scope)
                [ $# -ge 2 ] || die "--scope requires an argument"
                scope="$2"; shift 2 ;;
            --backup-existing-files)
                BACKUP_EXISTING=1; shift ;;
            --source)
                [ $# -ge 2 ] || die "--source requires an argument"
                SOURCE_DIR="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown argument: $1" ;;
        esac
    done

    local agents
    agents="$(parse_agents_csv "$agents_csv" "skills")"
    scope="$(parse_scope "$scope" skills)"

    ensure_tarball

    local root store_dir
    if [ "$scope" = "local" ]; then
        root="$(pwd -P)"
        store_dir="${root}/.skills"
    else
        root="${HOME}"
        store_dir="${HOME}/.agents/.jmix/skills/${RESOLVED_VERSION_DIR}"
    fi

    local store_existed=0
    [ -d "$store_dir" ] && store_existed=1

    vlog "scope=${scope} root=${root} store=${store_dir}"
    install_skills_to_store "$store_dir"
    emit_change "$([ "$store_existed" -eq 1 ] && printf updated || printf created)" dir "$store_dir"

    log ""
    log "Linking store skills into agent dirs"
    link_store_into_agents "$root" "$store_dir" "$agents"

    log ""
    log "Done. Installed ${scope} skills store at ${store_dir} and linked: $(printf '%s' "$agents" | tr ' ' ',' | sed 's/,/, /g')"
}

# =================================================================
# agents-md install (project-level)
# =================================================================

agents_md_dest_for_agent() {
    local agent="$1"
    local pwd_
    pwd_="$(pwd -P)"
    case "$agent" in
        claude)               printf '%s/CLAUDE.md' "$pwd_" ;;
        codex|opencode|junie) printf '%s/AGENTS.md' "$pwd_" ;;
        *) die "unknown agent '$1'" ;;
    esac
}

# Codex reads AGENTS.override.md instead of AGENTS.md in the same dir, and only
# the first 32 KiB (project_doc_max_bytes) of its project docs. Warns when
# either keeps the block in AGENTS.md $1 from Codex.
warn_if_codex_misses_block() {
    local dir offset
    dir="$(dirname "$1")"
    if [ -e "${dir}/AGENTS.override.md" ]; then
        log "  Note: Codex reads ${dir}/AGENTS.override.md instead of AGENTS.md there, so it does not see the Jmix block. Copy the block into it."
    fi
    # -a: a NUL or invalid UTF-8 byte must not turn the output into "Binary file
    # ... matches"; anything but digits is ignored.
    offset="$(LC_ALL=C grep -abF "$BLOCK_END" "$1" | tail -n 1 | cut -d: -f1)" || offset=""
    case "$offset" in ''|*[!0-9]*) offset="" ;; esac
    if [ -n "$offset" ] && [ $((offset + ${#BLOCK_END})) -gt 32768 ]; then
        log "  Note: Codex reads only the first 32 KiB of AGENTS.md, and the Jmix block ends past that. Move the block (with its markers) to the top."
    fi
}

# The marker pair delimiting the toolkit-managed region inside a project
# guidelines file. Must match content/guidelines-block.md and install.ps1 exactly.
BLOCK_BEGIN='<!-- BEGIN jmix-agent-toolkit -->'
BLOCK_END='<!-- END jmix-agent-toolkit -->'

# Succeeds when $1 holds a well-formed marker region. Each END is paired with
# the nearest preceding BEGIN, so an orphan or quoted BEGIN above the real block
# can never capture developer content. A half-marked file is unmanaged.
# Comparisons ignore an optional trailing \r (CRLF files) and a leading UTF-8
# BOM, so a marker line is recognised regardless of line-ending style or BOM.
# The BOM is written as an octal string literal and measured with length(),
# never sprintf("%c",239) or a literal 3: gawk in a UTF-8 locale renders %c as a
# CHARACTER (U+00EF -> two bytes) and counts substr() in characters, so both the
# constant and the offsets differ from mawk and BSD awk. Octal escapes give the
# raw bytes everywhere, and length()/blen is right under either model.
has_guidelines_block() {
    [ -f "$1" ] || return 1
    awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
        BEGIN { bom = "\357\273\277"; blen = length(bom) }
        {
            sub(/\r$/, "")
            if (substr($0, 1, blen) == bom) $0 = substr($0, blen + 1)
            if ($0 == b) { candidate = NR; next }
            if ($0 == e && candidate) {
                found = 1; exit
            }
        }
        END { exit found ? 0 : 1 }
    ' "$1"
}

# Prints $1 to stdout with its marker region (markers included) replaced by the
# whole content of block file $2, which carries its own markers. Marker
# comparisons ignore an optional trailing \r and a leading UTF-8 BOM, but every
# byte outside the replaced region is reproduced exactly as read -- only the
# comparison is normalised, never what gets written back. The END marker's own
# line ending (its trailing \r, if any, and the \n) is taken from the file
# being edited, not from the block, so a CRLF file gets CRLF right after the
# inserted block instead of the block's own LF -- matching install.ps1, which
# leaves that same byte range untouched.
# $1 - existing guidelines file   $2 - block file
replace_guidelines_block() {
    awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" -v h="## Jmix" -v blockfile="$2" '
        BEGIN {
            bom = "\357\273\277"; blen = length(bom)
            while ((getline line < blockfile) > 0) block = block line "\n"
            trimmed_block = block
            sub(/[\r\n]+$/, "", trimmed_block)
        }
        {
            raw[NR] = $0
            norm = $0
            sub(/\r$/, "", norm)
            if (substr(norm, 1, blen) == bom) norm = substr(norm, blen + 1)
            if (norm == b) { candidate = NR; owned = 0; next }
            if (candidate && NR == candidate + 1 && norm == h) owned = 1
            if (norm == e && candidate) {
                fallback_start = candidate; fallback_finish = NR
                if (owned) { preferred_start = candidate; preferred_finish = NR }
                candidate = 0; owned = 0
            }
        }
        END {
            if (preferred_start) { start = preferred_start; finish = preferred_finish }
            else                 { start = fallback_start;  finish = fallback_finish }
            found = (start && finish)
            for (i = 1; i <= NR; i++) {
                if (found && i == start) {
                    if (substr(raw[i], 1, blen) == bom) printf "%s", bom
                    printf "%s", trimmed_block
                    cr = (raw[finish] ~ /\r$/) ? "\r" : ""
                    printf "%s\n", cr
                    i = finish
                } else {
                    print raw[i]
                }
            }
        }
    ' "$1"
}

# Skill names a shipped (pre-block) guidelines file may reference: the toolkit's
# own skills plus the names its earliest files used. A closed set, deliberately
# NOT a bare `jmix-[a-z-]` -- a developer's own file can mention jmix-flowui or
# a github.com/jmix-framework URL without being ours. Must match install.ps1.
LEGACY_SKILL_NAMES_RE='jmix-(add-dialog-detail-flow|add-entity-event-listener|add-i18n-keys|configure-fetch-plan|create-composition-detail-view|create-custom-ui-component|create-detail-view|create-dto-entity|create-entity|create-enum|create-fragment|create-list-view|create-liquibase-changelog|create-resource-role|create-row-level-role|create-service|create-test|fetch-plans|ide-static-analysis|role-based-access|run-background-code|services|style-ui|verify-api-symbol|verify-bootrun)'

# Succeeds when $1 looks like a guidelines file this toolkit installed before the
# block existed. Both conditions must hold: the first non-blank line is one of
# the three headings the toolkit has ever shipped, and the body carries one of
# the toolkit's section headings or skill names. The first-line extraction
# ignores an optional trailing \r and a leading UTF-8 BOM so CRLF/BOM files are
# recognised the same as plain LF ones.
looks_like_legacy_guidelines() {
    local first
    first="$(awk '
        BEGIN { bom = "\357\273\277"; blen = length(bom) }
        { sub(/\r$/, ""); if (substr($0, 1, blen) == bom) $0 = substr($0, blen + 1) }
        NF { print; exit }
    ' "$1")"
    case "$first" in
        '# Agent Instructions'|'# Coding Guidelines'|'# Jmix Coding Guidelines') ;;
        *) return 1 ;;
    esac
    grep -qi '^## Skill routing' "$1" || grep -q '^## Skills and MCP' "$1" \
        || grep -Eq "$LEGACY_SKILL_NAMES_RE" "$1"
}

# Moves staged file $1 over $2. A symlinked $2 (e.g. CLAUDE.md -> AGENTS.md) is
# written through instead, so the link itself survives.
commit_staged() {
    if [ -L "$2" ]; then
        cat "$1" > "$2" && rm -f "$1"
    else
        mv "$1" "$2"
    fi
}

# A mktemp file starts as 0600. Copy the destination's permission bits onto it
# before an atomic rename so updating guidelines does not make a shared project
# unreadable to other users. Symlinks are written through by commit_staged().
preserve_dest_mode() {
    local staged="$1" dest="$2" mode
    [ -L "$dest" ] && return 0
    mode="$(stat -c '%a' "$dest" 2>/dev/null || stat -f '%Lp' "$dest")" \
        || die "cannot read permissions of ${dest}"
    chmod "$mode" "$staged" || die "cannot preserve permissions of ${dest}"
}

# Succeeds when CLAUDE.md $1 already gets the block through the AGENTS.md next
# to it: AGENTS.md carries the block, and CLAUDE.md either is that same file
# (symlink or hard link) or @-imports it -- Claude Code merges `@AGENTS.md`
# imports at load time. Installing the block into CLAUDE.md as well would only
# duplicate it.
claude_md_covered_by_agents_md() {
    local claude_md="$1" agents_md
    agents_md="$(dirname "$claude_md")/AGENTS.md"
    has_guidelines_block "$agents_md" || return 1
    [ "$claude_md" -ef "$agents_md" ] && return 0
    [ -f "$claude_md" ] && grep -Eq '(^|[[:space:]])@(\./)?AGENTS\.md([[:space:]]|$)' "$claude_md"
}

# Installs the block for agent $1, then checks what could still hide it from
# the agent (see the helpers above).
install_guidelines_block_for() {
    local dest
    dest="$(agents_md_dest_for_agent "$1")"
    write_guidelines_block "$1" "$dest"
    if [ "$1" = codex ]; then
        warn_if_codex_misses_block "$dest"
    fi
}

# Writes the toolkit-managed block for agent $1 into project guidelines file $2.
# Four branches, in order:
#   1. no file            -> write the block alone
#   2. markers present    -> replace only that region, no backup
#   3. legacy toolkit file-> back up, replace whole file
#   4. anything else      -> back up, add the block, keep everything they wrote:
#                            on top of an AGENTS.md (Codex reads only its first
#                            32 KiB), at the end of any other file
# Before 2-4, a CLAUDE.md that already gets the block through AGENTS.md (see
# claude_md_covered_by_agents_md) is skipped, and a dest that exists but is not
# a file is an error.
write_guidelines_block() {
    local agent="$1" dest="$2"
    local label dest_dir tmp backup
    label="$(agent_label "$agent")"

    [ -f "$SOURCE_GUIDELINES_BLOCK" ] \
        || die "guidelines-block.md not found in ${RESOLVED_VERSION_DIR}"

    dest_dir="$(dirname "$dest")"
    mkdir -p "$dest_dir" || die "cannot create directory ${dest_dir}"

    if [ ! -e "$dest" ]; then
        cp "$SOURCE_GUIDELINES_BLOCK" "$dest" || die "cannot copy to ${dest}"
        log "  Installed: ${dest}"
        emit_change created file "$dest"
        log "  Project guidelines installed for ${label}"
        return 0
    fi

    [ -f "$dest" ] || die "cannot merge guidelines into ${dest}: it exists but is not a file"

    if [ "$agent" = claude ] && claude_md_covered_by_agents_md "$dest"; then
        log "  Skipped: ${dest} (imports AGENTS.md, which already carries the block)"
        log "  Project guidelines reach ${label} through AGENTS.md"
        return 0
    fi

    tmp="$(mktemp "${dest_dir}/.jmix-guidelines.XXXXXX")" \
        || die "cannot create a temp file in ${dest_dir}"

    if has_guidelines_block "$dest"; then
        replace_guidelines_block "$dest" "$SOURCE_GUIDELINES_BLOCK" > "$tmp" \
            || { rm -f "$tmp"; die "cannot stage ${dest}"; }
        if cmp -s "$tmp" "$dest"; then
            rm -f "$tmp"
            log "  Unchanged: ${dest}"
            log "  Project guidelines already up to date for ${label}"
            return 0
        fi
        preserve_dest_mode "$tmp" "$dest"
        commit_staged "$tmp" "$dest" || { rm -f "$tmp"; die "cannot write ${dest}"; }
        log "  Updated: ${dest}"
        emit_change updated file "$dest"
        log "  Project guidelines installed for ${label}"
        return 0
    fi

    # Branches 3 and 4 rewrite content the toolkit does not own, so they always
    # back up, regardless of --backup-existing-files (issue #17).
    backup="$(dedup_backup_path "$dest")"
    cp "$dest" "$backup" || { rm -f "$tmp"; die "cannot back up ${dest}"; }
    emit_change backed-up file "$backup"

    if looks_like_legacy_guidelines "$dest"; then
        cp "$SOURCE_GUIDELINES_BLOCK" "$tmp" || { rm -f "$tmp"; die "cannot stage ${dest}"; }
    elif [ "$(basename "$dest")" = AGENTS.md ]; then
        # A leading UTF-8 BOM stays the first bytes of the file.
        {
            if [ "$(head -c 3 "$dest")" = $'\xef\xbb\xbf' ]; then
                printf '\357\273\277'
                cat "$SOURCE_GUIDELINES_BLOCK"
                printf '\n'
                tail -c +4 "$dest"
            else
                cat "$SOURCE_GUIDELINES_BLOCK"
                printf '\n'
                cat "$dest"
            fi
        } > "$tmp" || { rm -f "$tmp"; die "cannot stage ${dest}"; }
    else
        {
            cat "$dest"
            if [ -n "$(tail -c 1 "$dest")" ]; then printf '\n'; fi
            printf '\n'
            cat "$SOURCE_GUIDELINES_BLOCK"
        } > "$tmp" || { rm -f "$tmp"; die "cannot stage ${dest}"; }
    fi
    preserve_dest_mode "$tmp" "$dest"
    commit_staged "$tmp" "$dest" || { rm -f "$tmp"; die "cannot write ${dest}"; }

    log "  Updated: ${dest} (backup: $(basename "$backup"))"
    emit_change updated file "$dest"
    log "  Project guidelines installed for ${label}"
}

# Installs the block for every agent in $1 (space-separated), AGENTS.md agents
# before claude so claude_md_covered_by_agents_md sees AGENTS.md in its final
# state whatever order the agents were given in. $2=1 keeps going after a
# failed agent (wizard).
install_guidelines_blocks() {
    local agents="$1" lenient="${2:-0}" ordered="" agent
    for agent in codex opencode junie claude; do
        case " $agents " in *" ${agent} "*) ordered="${ordered} ${agent}" ;; esac
    done
    for agent in $ordered; do
        if [ "$lenient" -eq 1 ]; then
            install_guidelines_block_for "$agent" || true
        else
            install_guidelines_block_for "$agent"
        fi
    done
}

cmd_agents_md() {
    local agents_csv=""

    local _argc=-1
    while [ $# -gt 0 ]; do
        [ "$#" -ne "$_argc" ] || die "argument parser made no progress near: $1"
        _argc=$#
        case "$1" in
            --agents)
                [ $# -ge 2 ] || die "--agents requires an argument"
                agents_csv="$2"; shift 2 ;;
            --backup-existing-files)
                BACKUP_EXISTING=1; shift ;;
            --source)
                [ $# -ge 2 ] || die "--source requires an argument"
                SOURCE_DIR="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown argument: $1" ;;
        esac
    done

    local agents
    agents="$(parse_agents_csv "$agents_csv" "agents-md")"

    log "Project guidelines target directory: $(pwd -P)"
    ensure_tarball
    install_guidelines_blocks "$agents"
}

# =================================================================
# MCP registration (shared by mcp-jetbrains, mcp-context7, playwright)
# =================================================================
#
# Servers are registered in each agent's user config, so they serve every
# project:
#
#   agent           user config
#   claude          ~/.claude.json via `claude mcp add --scope user`
#   codex           ${CODEX_HOME:-~/.codex}/config.toml
#   opencode        ${XDG_CONFIG_HOME:-~/.config}/opencode/opencode.json
#   junie           ${JUNIE_HOME:-~/.junie}/mcp/mcp.json
#
# With claude, Claude Desktop is set up too when it is installed (see
# mcp_desktop): claude_desktop_config.json.
#
# ~/.claude.json is Claude Code's own state file, so it is changed only through
# the claude CLI. Every other file is merged in place, with no agent CLI needed
# (Studio runs this from the IDE process): other servers and keys are kept, an
# unchanged file is not rewritten, and a file that cannot be parsed is left
# alone and the step fails.

# Prints the Claude Desktop config file, or fails when Claude Desktop has no
# config folder here (not installed, or never started).
claude_desktop_config() {
    local dir
    case "$(uname -s 2>/dev/null)" in
        Darwin) dir="${HOME}/Library/Application Support/Claude" ;;
        Linux)  dir="${XDG_CONFIG_HOME:-${HOME}/.config}/Claude" ;;
        *) return 1 ;;
    esac
    [ -d "$dir" ] || return 1
    printf '%s/claude_desktop_config.json' "$dir"
}

# Prints the user MCP config file of agent $1 (see the table above).
mcp_config_file() {
    case "$1" in
        codex)    printf '%s/config.toml' "${CODEX_HOME:-${HOME}/.codex}" ;;
        opencode) printf '%s/opencode/opencode.json' "${XDG_CONFIG_HOME:-${HOME}/.config}" ;;
        junie)    printf '%s/mcp/mcp.json' "${JUNIE_HOME:-${HOME}/.junie}" ;;
        *) return 1 ;;
    esac
}

# Moves staged file $1 over config file $2 unless they are identical, logging
# the outcome. A new file gets mode $3; an existing one keeps its mode, and a
# symlinked one is written through (see preserve_dest_mode / commit_staged).
# With MCP_PRIVATE=1 (the entry carries the Context7 key) the file ends up
# readable by its owner only, whatever mode it had.
commit_config() {
    local tmp="$1" file="$2" mode="$3"
    # Narrow the old mode before copying it or writing through a symlink.
    if [ "$MCP_PRIVATE" = 1 ] && [ -e "$file" ]; then
        chmod go-rwx "$file" || { rm -f "$tmp"; err "cannot restrict the permissions of ${file}"; return 1; }
    fi
    if [ -f "$file" ] && cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
        log "  Unchanged: ${file}"
        CONFIG_CHANGED=0
    elif [ -e "$file" ]; then
        preserve_dest_mode "$tmp" "$file"
        commit_staged "$tmp" "$file" || { rm -f "$tmp"; err "cannot write ${file}"; return 1; }
        log "  Updated: ${file}"
        emit_change updated file "$file"
        CONFIG_CHANGED=1
    else
        if ! { chmod "$mode" "$tmp" && mv "$tmp" "$file"; }; then
            rm -f "$tmp"; err "cannot write ${file}"; return 1
        fi
        log "  Created: ${file}"
        emit_change created file "$file"
        CONFIG_CHANGED=1
    fi
}

# Reads JSON on stdin, sets .[$1][$2] = $3 (compact JSON) and prints the result.
# Uses jq, or node when jq is missing; fails on input that is not a JSON object
# (JSONC comments included) or when neither tool exists.
json_merge() {
    if command -v jq >/dev/null 2>&1; then
        jq --arg r "$1" --arg n "$2" --argjson e "$3" \
            'if type == "object" then .[$r] = ((.[$r] // {}) | .[$n] = $e) else error("not an object") end'
    elif command -v node >/dev/null 2>&1; then
        node -e '
            const [root, name, entry] = process.argv.slice(1);
            let text = "";
            process.stdin.on("data", d => text += d).on("end", () => {
                const o = JSON.parse(text);
                if (o === null || typeof o !== "object" || Array.isArray(o)) process.exit(1);
                o[root] = (o[root] && typeof o[root] === "object") ? o[root] : {};
                o[root][name] = JSON.parse(entry);
                process.stdout.write(JSON.stringify(o, null, 2) + "\n");
            });' "$1" "$2" "$3"
    else
        return 1
    fi
}

# Sets server $3 = $4 (compact JSON) under the "$2" object of JSON file $1.
# $5 - mode for a newly created file
json_set_entry() {
    local file="$1" root="$2" name="$3" entry="$4" mode="$5" dir tmp
    if { [ -e "$file" ] || [ -L "$file" ]; } && [ ! -f "$file" ]; then
        err "cannot update ${file}: it exists but is not a regular file"
        return 1
    fi
    if [ -e "$file" ] && [ ! -r "$file" ]; then
        err "cannot read ${file}; it was left unchanged"
        return 1
    fi
    dir="$(dirname "$file")"
    mkdir -p "$dir" || { err "cannot create ${dir}"; return 1; }
    tmp="$(mktemp "${dir}/.jmix-mcp.XXXXXX")" || { err "cannot create a temp file in ${dir}"; return 1; }
    # A new or blank file needs no merge, so no jq/node either; a re-run finds
    # this exact text and leaves it alone.
    printf '{\n  "%s": {\n    "%s": %s\n  }\n}\n' "$root" "$name" "$entry" > "$tmp"
    if [ ! -f "$file" ] || ! grep -q '[^[:space:]]' "$file" || cmp -s "$tmp" "$file"; then
        commit_config "$tmp" "$file" "$mode"
        return
    fi
    # Merge into the existing content; a UTF-8 BOM (Windows editors) is dropped.
    # pipefail (set at the top) fails the pipeline when json_merge does.
    if ! LC_ALL=C sed $'1s/^\xef\xbb\xbf//' "$file" \
        | json_merge "$root" "$name" "$entry" > "$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        if command -v jq >/dev/null 2>&1 || command -v node >/dev/null 2>&1; then
            err "cannot update ${file}: it is not plain JSON (comments are not supported). Add the \"${name}\" server to it manually, see README."
        else
            err "cannot update ${file}: editing it needs jq or node. Install one of them, or add the \"${name}\" server manually, see README."
        fi
        return 1
    fi
    commit_config "$tmp" "$file" "$mode"
}

# Sets table [$2] of TOML file $1 to body $3: an existing [$2] (with its
# sub-tables) is replaced where it stands, otherwise the table is appended.
# Fails, leaving the file alone, when $2 is defined another way (dotted keys,
# or inline in a parent) that this line-based edit cannot replace.
# $4 - mode for a newly created file; $5=scan only checks how [$2] is defined,
# for a file that is read but not written (triple-quoted strings elsewhere do
# not matter then).
toml_set_table() {
    local file="$1" table="$2" body="$3" mode="$4" scan="${5:-}" dir tmp rc=0
    if { [ -e "$file" ] || [ -L "$file" ]; } && [ ! -f "$file" ]; then
        err "cannot update ${file}: it exists but is not a regular file"
        return 1
    fi
    if [ -e "$file" ] && [ ! -r "$file" ]; then
        err "cannot read ${file}; it was left unchanged"
        return 1
    fi
    # shortcut: refuse triple-quoted content; use a TOML parser to edit it safely.
    if [ -z "$scan" ] && [ -f "$file" ] && grep -Eq "\"\"\"|'''" "$file"; then
        err "cannot update ${file}: multi-line TOML strings are not supported. Add [${table}] manually, see README."
        return 1
    fi
    [ -n "$scan" ] && [ ! -f "$file" ] && return 0
    if [ -n "$scan" ]; then
        tmp=/dev/null
    else
        dir="$(dirname "$file")"
        mkdir -p "$dir" || { err "cannot create ${dir}"; return 1; }
        tmp="$(mktemp "${dir}/.jmix-mcp.XXXXXX")" || { err "cannot create a temp file in ${dir}"; return 1; }
    fi
    if [ -f "$file" ]; then
        # Comments before the next table usually introduce that table.
        JMIX_TOML_BODY="$body" awk -v t="$table" '
            function norm(s) { gsub(/[ \t"]/, "", s); gsub(sprintf("%c", 39), "", s); return s }
            function emit(s) { out[++n] = s; if (s !~ /^[ \t\r]*$/) last = n }
            function flush(  i) { for (i = 1; i <= np; i++) emit(pend[i]); np = 0 }
            # The BOM is found with index() and measured with length(): gawk in
            # a UTF-8 locale counts it as one character, and BSD awk compares
            # strings by collation, which ignores it ("\357\273\277x" == "x").
            BEGIN { body = ENVIRON["JMIX_TOML_BODY"]; bom = "\357\273\277"; blen = length(bom) }
            {
                line = $0; probe = line
                if (NR == 1 && index(probe, bom) == 1) { probe = substr(probe, blen + 1); hasbom = 1 }
            }
            probe ~ /^[ \t]*\[/ {
                h = probe; sub(/^[ \t]*\[+/, "", h); sub(/\].*$/, "", h); h = norm(h)
                if (skip) flush()
                skip = (h == t || index(h, t ".") == 1)
                if (!skip) { cur = h; emit(line); next }
                if (!done) { emit((NR == 1 && hasbom ? bom : "") "[" t "]"); emit(body); done = 1 }
                next
            }
            skip {
                if (probe ~ /^[ \t]*(#.*)?\r?$/) pend[++np] = line; else np = 0
                next
            }
            {
                if (index(probe, "=")) {
                    k = probe; sub(/=.*$/, "", k); k = norm(k)
                    full = (cur == "" ? k : cur "." k)
                    if (full == t || index(full, t ".") == 1 || index(t, full ".") == 1) { conflict = 1; exit }
                }
                emit(line)
            }
            END {
                if (conflict) exit 3
                if (skip) flush()
                for (i = 1; i <= last; i++) print out[i]
                if (!done) {
                    if (last) print ""
                    print "[" t "]"
                    print body
                }
            }
        ' "$file" > "$tmp" || rc=$?
    else
        printf '[%s]\n%s\n' "$table" "$body" > "$tmp"
    fi
    if [ "$rc" -ne 0 ]; then
        if [ -n "$scan" ]; then
            err "cannot check ${file}: [${table}] is defined there in a form this installer cannot read. Define it as an explicit [${table}] table, or remove it, then re-run."
        else
            rm -f "$tmp"
            err "cannot update ${file}: [${table}] is defined there in a form this installer does not edit. Change it manually, see README."
        fi
        return 1
    fi
    [ -n "$scan" ] && return 0
    commit_config "$tmp" "$file" "$mode"
}

# Prints "url" or "command" -- the transport of table [$2] in Codex config $1 --
# or nothing when the file or the table is absent.
codex_transport() {
    [ -r "$1" ] || return 0
    awk -v t="$2" '
        function norm(s) { gsub(/[ \t"]/, "", s); gsub(sprintf("%c", 39), "", s); return s }
        BEGIN { bom = "\357\273\277"; blen = length(bom) }
        NR == 1 && index($0, bom) == 1 { $0 = substr($0, blen + 1) }
        /^[ \t]*\[/ { h = $0; sub(/^[ \t]*\[+/, "", h); sub(/\].*$/, "", h); in_t = (norm(h) == t); next }
        in_t && index($0, "=") { k = $0; sub(/=.*$/, "", k); k = norm(k); if (k == "url" || k == "command") { print k; exit } }
    ' "$1"
}

# Codex merges [mcp_servers.X] of the user config with the project configs of
# the current directory up to its git root (the current directory alone outside
# a repository), key by key, and refuses its whole configuration when the
# result mixes url (HTTP) and command (stdio). Fails when one of those project
# configs defines the server with the other transport; they are only read,
# never changed.
# $1 - server name   $2 - TOML body
codex_check_project_layers() {
    local user mine theirs cwd root dir project
    user="$(mcp_config_file codex)"
    case "$2" in url*) mine="url" ;; *) mine="command" ;; esac
    cwd="$(pwd -P)" || { err "cannot determine the current directory"; return 1; }
    root="$cwd"
    while [ ! -e "$root/.git" ]; do
        if [ "$root" = / ]; then root="$cwd"; break; fi
        root="$(dirname "$root")"
    done
    dir="$cwd"
    while :; do
        project="${dir}/.codex/config.toml"
        # Run from the user's home, the project config is the user config.
        if [ "$project" != "$user" ] && ! [ "$project" -ef "$user" ]; then
            toml_set_table "$project" "mcp_servers.$1" "$2" 644 scan || return 1
            theirs="$(codex_transport "$project" "mcp_servers.$1")" || return 1
            if [ -n "$theirs" ] && [ "$theirs" != "$mine" ]; then
                if [ "$1" = jetbrains ] && [ "$JB_GUESSED" = 1 ]; then
                    err "${project} defines [mcp_servers.jetbrains] with another transport, and IntelliJ IDEA is not reachable to tell which one it serves. Start it with its MCP server enabled and re-run."
                else
                    err "${project} defines [mcp_servers.$1] with another transport, which Codex cannot merge with the user config. Remove or change that table, then re-run."
                fi
                return 1
            fi
        fi
        [ "$dir" != "$root" ] || break
        dir="$(dirname "$dir")"
    done
}

# Prints the claude CLI: the one on PATH, else where Claude Code's installers
# put it -- an IDE started from the desktop often lacks ~/.local/bin on PATH.
claude_cli() {
    local cli
    cli="$(command -v claude 2>/dev/null)" && { printf '%s' "$cli"; return 0; }
    for cli in "${HOME}/.local/bin/claude" "${HOME}/.claude/local/claude"; do
        [ -x "$cli" ] && { printf '%s' "$cli"; return 0; }
    done
    return 1
}

# Registers a Claude Code user-scope server through the claude CLI. `mcp add`
# exits 1 when the name exists, so any entry is removed first. Its output is
# discarded: it echoes the command line, the Context7 key included.
# $1 - server name, $@ after it - arguments of `claude mcp add`
mcp_claude_user() {
    local name="$1" cli
    shift
    if ! cli="$(claude_cli)"; then
        log "  Skipped: 'claude' CLI not found on PATH or in ~/.local/bin. Install Claude Code and re-run."
        return 0
    fi
    "$cli" mcp remove --scope user "$name" >/dev/null 2>&1 || true
    "$cli" mcp add "$@" >/dev/null || { err "claude mcp add ${name} failed"; return 1; }
    MCP_WRITTEN=1
    log "  Registered ${name} in the Claude Code user config"
}

# Writes MCP server $2 into the user config of agent $1. $3 is the entry:
# compact JSON, or the TOML table body for codex. For claude the remaining
# arguments are passed to `claude mcp add` instead.
mcp_write() {
    local agent="$1" name="$2" entry="$3" file
    shift 3
    if [ "$agent" = claude ]; then
        mcp_claude_user "$name" "$@"
        return
    fi
    file="$(mcp_config_file "$agent")" || { err "no MCP config file for ${agent}"; return 1; }
    # A new file is private: user configs may hold the Context7 key.
    case "$agent" in
        codex)
            codex_check_project_layers "$name" "$entry" \
                && toml_set_table "$file" "mcp_servers.${name}" "$entry" 600 ;;
        opencode)
            json_set_entry "$file" mcp "$name" "$entry" 600 ;;
        *)
            json_set_entry "$file" mcpServers "$name" "$entry" 600 ;;
    esac || return 1
    MCP_WRITTEN=1
}

# Claude Desktop takes stdio servers only and has no project scope. It is set
# up together with claude whenever it is installed here, i.e. its config
# folder exists; otherwise nothing is written.
# $1 - server name   $2 - stdio entry (compact JSON)
mcp_desktop() {
    local file
    file="$(claude_desktop_config)" || return 0
    CONFIG_CHANGED=0
    json_set_entry "$file" mcpServers "$1" "$2" 600 || return 1
    if [ "$CONFIG_CHANGED" = 1 ]; then
        log "  Quit Claude Desktop completely (not just its window) and start it again to load the change."
    fi
}

# Succeeds when claude is among the selected agents and Claude Desktop is installed.
desktop_selected() {
    case " $MCP_AGENTS_SEL " in *" claude "*) claude_desktop_config >/dev/null ;; *) return 1 ;; esac
}

# Runs the MCP step for every agent and returns 1 if any of them failed.
# $1 - per-agent function   $2 - agents   $3.. - extra arguments for $1
mcp_for_agents() {
    local fn="$1" agents="$2" agent rc=0
    MCP_WRITTEN_AGENTS=""
    shift 2
    for agent in $agents; do
        log ""
        MCP_WRITTEN=0
        "$fn" "$agent" "$@" || rc=1
        [ "$MCP_WRITTEN" = 0 ] || MCP_WRITTEN_AGENTS="${MCP_WRITTEN_AGENTS} ${agent}"
    done
    return $rc
}

# Parses the shared MCP subcommand options into MCP_AGENTS_SEL / MCP_KEY.
# $1 - subcommand name; the rest are the arguments.
parse_mcp_args() {
    local sub="$1" agents_csv=""
    shift
    MCP_KEY=""
    local _argc=-1
    while [ $# -gt 0 ]; do
        [ "$#" -ne "$_argc" ] || die "argument parser made no progress near: $1"
        _argc=$#
        case "$1" in
            --agents)
                [ $# -ge 2 ] || die "--agents requires an argument"
                agents_csv="$2"; shift 2 ;;
            --scope)
                die "${sub}: MCP servers are always registered in the user config; --scope applies to skills only" ;;
            --context7-key)
                [ "$sub" = mcp-context7 ] || die "unknown argument: $1"
                [ $# -ge 2 ] || die "--context7-key requires an argument"
                MCP_KEY="$2"; shift 2 ;;
            --backup-existing-files)
                BACKUP_EXISTING=1; shift ;;
            --source)
                # Accepted like every subcommand; MCP steps need no content.
                [ $# -ge 2 ] || die "--source requires an argument"
                shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown argument: $1" ;;
        esac
    done
    MCP_AGENTS_SEL="$(parse_agents_csv "$agents_csv" "$sub")"
}

# =================================================================
# MCP install - JetBrains
# =================================================================

# IntelliJ 2026.1+ serves Streamable HTTP at /stream; 2025.2/2025.3 serve only
# SSE at /sse and answer 404 there. A HEAD request tells them apart without
# opening an MCP session. When the IDE does not answer (server disabled, IDE
# closed), assume 2026.1+ and say so.
detect_jetbrains_transport() {
    local code=""
    if command -v curl >/dev/null 2>&1; then
        # --noproxy: an http_proxy would answer instead of the IDE.
        code="$(curl -s --noproxy '*' -o /dev/null -I -m 3 -w '%{http_code}' "http://127.0.0.1:${JB_PORT}/stream" 2>/dev/null)" || true
    fi
    case "$code" in
        404)
            JB_TRANSPORT=sse
            log "IntelliJ IDEA MCP server on port ${JB_PORT} has no /stream endpoint (IntelliJ IDEA before 2026.1): using SSE." ;;
        ''|000)
            JB_TRANSPORT=stream
            JB_GUESSED=1
            log "IntelliJ IDEA MCP server is not reachable on port ${JB_PORT}; assuming IntelliJ IDEA 2026.1+."
            log "Enable it in Settings | Tools | MCP Server. On IntelliJ IDEA 2025.x, re-run this step once it is enabled." ;;
        *)
            JB_TRANSPORT=stream ;;
    esac
}

# $1 - agent
install_jetbrains_for() {
    local agent="$1" base="http://127.0.0.1:${JB_PORT}"
    # A stdio-to-SSE bridge for clients without an HTTP transport the IDE has.
    local bridge_json="{\"command\":\"npx\",\"args\":[\"-y\",\"mcp-remote\",\"${base}/sse\",\"--transport\",\"sse-only\"]}"
    log "[JetBrains MCP] $(agent_label "$agent")"
    if [ "$agent" = junie ]; then
        log "  Junie runs inside IntelliJ IDEA and already has native IDE access. No JetBrains MCP needed."
        return 0
    fi
    local rc=0
    if [ "$JB_TRANSPORT" = stream ]; then
        case "$agent" in
            claude)   mcp_write claude jetbrains "" --scope user --transport http jetbrains "${base}/stream" ;;
            codex)    mcp_write codex jetbrains "url = \"${base}/stream\"" ;;
            opencode) mcp_write opencode jetbrains "{\"type\":\"remote\",\"url\":\"${base}/stream\",\"enabled\":true}" ;;
        esac || rc=1
    else
        case "$agent" in
            claude)   mcp_write claude jetbrains "" --scope user --transport sse jetbrains "${base}/sse" ;;
            # Codex has no SSE transport.
            codex)    mcp_write codex jetbrains "command = \"npx\"
args = [\"-y\", \"mcp-remote\", \"${base}/sse\", \"--transport\", \"sse-only\"]
startup_timeout_sec = 60" ;;
            opencode) mcp_write opencode jetbrains "{\"type\":\"remote\",\"url\":\"${base}/sse\",\"enabled\":true}" ;;
        esac || rc=1
    fi
    # Claude Desktop has no HTTP transport for local servers: always the bridge.
    if [ "$agent" = claude ]; then
        mcp_desktop jetbrains "$bridge_json" || rc=1
    fi
    return $rc
}

cmd_mcp_jetbrains() {
    parse_mcp_args mcp-jetbrains "$@"
    detect_jetbrains_transport
    local rc=0
    mcp_for_agents install_jetbrains_for "$MCP_AGENTS_SEL" || rc=1
    if desktop_selected; then
        warn_if_no_npx "Claude Desktop's JetBrains MCP bridge"
    elif [ "$JB_TRANSPORT" = sse ]; then
        case " $MCP_AGENTS_SEL " in *" codex "*) warn_if_no_npx "Codex's JetBrains MCP bridge" ;; esac
    fi
    return $rc
}

# =================================================================
# MCP install - Context7 (always user level: the entry carries the API key)
# =================================================================

# Fails for an empty key or one that would need escaping: the key is spliced
# into JSON, TOML and an HTTP header as is.
context7_key_ok() {
    case "$1" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
}

# $1 - agent   $2 - API key
install_context7_for() {
    local agent="$1" key="$2"
    local stdio_json="{\"command\":\"npx\",\"args\":[\"-y\",\"@upstash/context7-mcp\"],\"env\":{\"CONTEXT7_API_KEY\":\"${key}\"}}"
    log "[Context7 MCP] $(agent_label "$agent")"
    case "$agent" in
        claude)
            local rc=0
            mcp_write claude context7 "" \
                --scope user --transport http context7 "$CONTEXT7_URL" --header "Authorization: Bearer ${key}" || rc=1
            mcp_desktop context7 "$stdio_json" || rc=1
            return $rc ;;
        codex)    mcp_write codex context7 "url = \"${CONTEXT7_URL}\"
http_headers = { Authorization = \"Bearer ${key}\" }" ;;
        opencode) mcp_write opencode context7 "{\"type\":\"remote\",\"url\":\"${CONTEXT7_URL}\",\"headers\":{\"Authorization\":\"Bearer ${key}\"},\"enabled\":true}" ;;
        # Junie (and Claude Desktop above): stdio, the key in the environment, not in argv.
        *)        mcp_write "$agent" context7 "$stdio_json" ;;
    esac
}

cmd_mcp_context7() {
    parse_mcp_args mcp-context7 "$@"
    local key="$MCP_KEY"
    if [ -z "$key" ]; then
        key="$(prompt 'Context7 API key' '')"
        [ -n "$key" ] || die "Context7 API key is required"
    fi
    context7_key_ok "$key" || die "Context7 API key may contain only letters, digits, '.', '_' and '-'"
    local rc=0
    MCP_PRIVATE=1
    mcp_for_agents install_context7_for "$MCP_AGENTS_SEL" "$key" || rc=1
    MCP_PRIVATE=0
    case " $MCP_AGENTS_SEL " in
        *" junie "*) warn_if_no_npx "Context7 for Junie" ;;
        *) desktop_selected && warn_if_no_npx "Context7 for Claude Desktop" ;;
    esac
    return $rc
}

# =================================================================
# MCP install - Playwright
# =================================================================

# Earlier toolkit versions installed the playwright-cli skill into a global
# store and linked it into the agent skill dirs. The step now registers the
# MCP server instead. Remove the shared store only after all agents have it.
remove_legacy_playwright_skills() {
    local store="${HOME}/.agents/.playwright" dir link agent
    [ -d "$store" ] || return 0
    # The global store and even agent directories may be shared by all agents.
    for agent in $ALL_AGENTS; do
        case " $1 " in *" $agent "*) ;; *) return 0 ;; esac
    done
    for dir in "${HOME}/.claude/skills" "${HOME}/.agents/skills" "${HOME}/.junie/skills"; do
        for link in "$dir"/*; do
            [ -L "$link" ] || continue
            # Only links into the store: ../.playwright/skills/X from
            # ~/.agents/skills, .../.agents/.playwright/skills/X elsewhere.
            case "$(readlink "$link")" in
                ../.playwright/skills/*|*/.agents/.playwright/skills/*)
                    rm -f "$link" && log "  Removed old playwright-cli skill link ${link}" ;;
            esac
        done
    done
    # A store that cannot be removed is reported, not a reason to stop.
    if rm -rf "$store"; then
        log "  Removed old playwright-cli skills store ${store}"
    else
        err "cannot fully remove the old playwright-cli skills store ${store}"
    fi
}

# $1 - agent
install_playwright_for() {
    local agent="$1"
    log "[Playwright MCP] $(agent_label "$agent")"
    local stdio_json="{\"command\":\"npx\",\"args\":[\"-y\",\"${PLAYWRIGHT_MCP_PKG}\"]}"
    case "$agent" in
        claude)
            local rc=0
            mcp_write claude playwright "" --scope user playwright -- npx -y "$PLAYWRIGHT_MCP_PKG" || rc=1
            mcp_desktop playwright "$stdio_json" || rc=1
            return $rc ;;
        # The first npx download can outlast Codex's default startup timeout.
        codex)    mcp_write codex playwright "command = \"npx\"
args = [\"-y\", \"${PLAYWRIGHT_MCP_PKG}\"]
startup_timeout_sec = 60" ;;
        opencode) mcp_write opencode playwright "{\"type\":\"local\",\"command\":[\"npx\",\"-y\",\"${PLAYWRIGHT_MCP_PKG}\"],\"enabled\":true}" ;;
        *)        mcp_write "$agent" playwright "$stdio_json" ;;
    esac
}

cmd_playwright() {
    parse_mcp_args playwright "$@"
    local rc=0
    mcp_for_agents install_playwright_for "$MCP_AGENTS_SEL" || rc=1
    if [ "$rc" = 0 ]; then
        remove_legacy_playwright_skills "$MCP_WRITTEN_AGENTS"
    fi
    warn_if_no_npx "The Playwright MCP server"
    return $rc
}

# =================================================================
# Wizard
# =================================================================

wizard_pick_agent() {
    local default_choice="$1"
    shift
    local prompt_label="$1"
    shift
    local options="$*"

    {
        log ""
        log "$prompt_label"
        printf '  a) For all agents\n'
        local i=1
        local opt
        for opt in $options; do
            printf '  %d) %s\n' "$i" "$(agent_label "$opt")"
            i=$((i + 1))
        done
        printf '  s) Skip\n'
    } >&2

    local answer
    answer="$(prompt 'Choice' "$default_choice")"
    case "$answer" in
        s|S|skip|SKIP) printf 'skip'; return 0 ;;
        a|A|all|ALL) printf '%s' "$options"; return 0 ;;
    esac
    if ! printf '%s' "$answer" | grep -Eq '^[0-9]+$'; then
        log "Unrecognized choice '${answer}'. Skipping." >&2
        printf 'skip'
        return 0
    fi
    local idx=1
    for opt in $options; do
        if [ "$idx" -eq "$answer" ]; then
            printf '%s' "$opt"
            return 0
        fi
        idx=$((idx + 1))
    done
    log "Unrecognized choice '${answer}'. Skipping." >&2
    printf 'skip'
}

cmd_wizard() {
    local _argc=-1
    while [ $# -gt 0 ]; do
        [ "$#" -ne "$_argc" ] || die "argument parser made no progress near: $1"
        _argc=$#
        case "$1" in
            --source)
                [ $# -ge 2 ] || die "--source requires an argument"
                SOURCE_DIR="$2"; shift 2 ;;
            --backup-existing-files)
                BACKUP_EXISTING=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown argument: $1" ;;
        esac
    done

    log "=== Jmix AI Agents Toolkit ==="
    log "Working directory: $(pwd -P)"

    local summary_skills="skipped"
    local summary_guidelines="skipped"
    local summary_jetbrains="skipped"
    local summary_context7="skipped"
    local summary_playwright="skipped"

    # Step 1: skills
    local sel
    sel="$(wizard_pick_agent all '[1/5] Install Jmix skills?' "$ALL_AGENTS")"
    if [ "$sel" != "skip" ]; then
        local scope_answer scope="local"
        scope_answer="$(prompt 'Install scope: (l)ocal project dir or (g)lobal user home' 'l')"
        case "$scope_answer" in g|G|global|GLOBAL) scope="global" ;; esac
        ensure_tarball
        local root store_dir
        if [ "$scope" = "local" ]; then
            root="$(pwd -P)"; store_dir="${root}/.skills"
        else
            root="${HOME}"; store_dir="${HOME}/.agents/.jmix/skills/${RESOLVED_VERSION_DIR}"
        fi
        install_skills_to_store "$store_dir" || true
        link_store_into_agents "$root" "$store_dir" "$sel" || true
        summary_skills="$sel (${scope})"
    fi

    # Step 2: agents-md
    sel="$(wizard_pick_agent all '[2/5] Merge Jmix coding guidelines into this directory?' "$ALL_AGENTS")"
    if [ "$sel" != "skip" ]; then
        if prompt_yes_no "Target directory: $(pwd -P). Proceed?" "y"; then
            ensure_tarball
            install_guidelines_blocks "$sel" 1
            summary_guidelines="$sel"
        else
            summary_guidelines="skipped (declined)"
        fi
    fi

    # Steps 3-5 reuse the subcommands: their only exits are argument errors,
    # which cannot happen with the values passed here.

    # Step 3: JetBrains MCP
    sel="$(wizard_pick_agent skip '[3/5] Connect agent to IntelliJ IDEA via JetBrains MCP?' "$JETBRAINS_AGENTS")"
    if [ "$sel" != "skip" ]; then
        cmd_mcp_jetbrains --agents "$(printf '%s' "$sel" | tr ' ' ',')" || true
        summary_jetbrains="$sel (user level)"
    fi

    # Step 4: Context7 MCP
    sel="$(wizard_pick_agent skip '[4/5] Connect agent to library docs via Context7 MCP?' "$ALL_AGENTS")"
    if [ "$sel" != "skip" ]; then
        local key
        key="$(prompt 'Context7 API key' '')"
        if context7_key_ok "$key"; then
            cmd_mcp_context7 --agents "$(printf '%s' "$sel" | tr ' ' ',')" --context7-key "$key" || true
            summary_context7="$sel (user level)"
        else
            log "API key missing or malformed, skipping Context7 setup."
            summary_context7="skipped (no key)"
        fi
    fi

    # Step 5: Playwright MCP
    sel="$(wizard_pick_agent skip '[5/5] Connect agent to a browser via Playwright MCP?' "$ALL_AGENTS")"
    if [ "$sel" != "skip" ]; then
        cmd_playwright --agents "$(printf '%s' "$sel" | tr ' ' ',')" || true
        summary_playwright="$sel (user level)"
    fi

    log ""
    log "=== Setup complete ==="
    log "  Skills:      ${summary_skills}"
    log "  Guidelines:  ${summary_guidelines}"
    log "  JetBrains:   ${summary_jetbrains}"
    log "  Context7:    ${summary_context7}"
    log "  Playwright:  ${summary_playwright}"
}

# =================================================================
# Main dispatch
# =================================================================

# Pull global options out of the args so every subcommand benefits.
_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --content-ref)
            [ $# -ge 2 ] || die "--content-ref requires an argument"
            [ -n "$2" ] || die "--content-ref cannot be empty"
            CONTENT_REF="$2"; shift 2 ;;
        --verbose|--debug)
            VERBOSE=1; shift ;;
        *)
            _args+=("$1"); shift ;;
    esac
done
set -- ${_args[@]+"${_args[@]}"}
debug_env

# The port is spliced into URLs, JSON and TOML.
case "$JB_PORT" in
    ''|*[!0-9]*) die "JMIX_IDE_MCP_PORT must be a port number (got '${JB_PORT}')" ;;
esac
[ "$JB_PORT" -ge 1 ] && [ "$JB_PORT" -le 65535 ] || die "JMIX_IDE_MCP_PORT must be between 1 and 65535 (got ${JB_PORT})"

if [ $# -eq 0 ]; then
    cmd_wizard
    exit $?
fi

case "$1" in
    skills)        shift; cmd_skills "$@" ;;
    agents-md)     shift; cmd_agents_md "$@" ;;
    mcp-jetbrains) shift; cmd_mcp_jetbrains "$@" ;;
    mcp-context7)  shift; cmd_mcp_context7 "$@" ;;
    playwright)    shift; cmd_playwright "$@" ;;
    -h|--help)     usage ;;
    --*)           cmd_wizard "$@" ;;
    *)             die "unknown subcommand: $1" ;;
esac
