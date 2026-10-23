#!/usr/bin/env bash
# Jmix AI Agents Toolkit installer.
#
# Default (no subcommand) launches an interactive wizard that guides through:
#   1. Installing Jmix skills (globally or into the project) into .agents/skills,
#      and for Claude Code also into .claude/skills. In the project the skills
#      are kept in .agents/skills and linked into .claude/skills; an old
#      .skills store is migrated and removed.
#   2. Adding project-level guidelines to AGENTS.md, and for Claude Code to
#      CLAUDE.md.
#   3. Registering MCP servers (JetBrains, Context7, Playwright) with the agents.
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
# Where --backup-existing-files moves replaced skill folders; empty means beside
# them. Set by select_skills_scope.
SKILL_BACKUP_DIR=""
VERBOSE=0

ALL_AGENTS="claude codex opencode junie cline"
MCP_SERVERS_ALL="jetbrains context7 playwright"

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

# Prints where --backup-existing-files moves skill folder $1: a deduped
# <path>.bak[N] beside it, or, when SKILL_BACKUP_DIR is set (local scope, where
# agents would read a .bak beside the skills as one more skill), a deduped
# <name>.bak[N] in that dir, created on first use.
skill_backup_path() {
    if [ -z "$SKILL_BACKUP_DIR" ]; then
        dedup_backup_path "$1"
        return
    fi
    mkdir -p "$SKILL_BACKUP_DIR" || die "cannot create ${SKILL_BACKUP_DIR}"
    dedup_backup_path "${SKILL_BACKUP_DIR}/$(basename "$1")"
}

# Replaces or installs skill folder $dest with a copy of $src. An existing
# $dest is backed up (see skill_backup_path) when BACKUP_EXISTING=1; otherwise
# it is deleted. A link at $dest is never followed. When backups go to
# SKILL_BACKUP_DIR (local scope, where an older layout linked the store's
# skills), a link is only removed: moved there, a relative one would dangle.
# Prints a per-item log line.
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
    if [ -L "$dest" ] && [ -n "$SKILL_BACKUP_DIR" ]; then
        rm -f "$dest" || die "cannot remove ${dest}"
    elif [ "$existed" -eq 1 ]; then
        if [ "$BACKUP_EXISTING" -eq 1 ]; then
            local backup
            backup="$(skill_backup_path "$dest")"
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

# Parses comma-separated list $1, given in option $3 of subcommand $2. Every
# value must be one of $4 (space-separated), in any case. Prints them
# space-separated, in $4's order, each once.
parse_csv() {
    local csv sub="$2" opt="$3" valid="$4" token result="" v
    csv="$(printf '%s' "$1" | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
    [ -n "$csv" ] || die "${sub}: ${opt} is required (one or more of: $(printf '%s' "$valid" | tr ' ' ','))"
    for token in $(printf '%s' "$csv" | tr ',' ' '); do
        case " ${valid} " in
            *" ${token} "*) ;;
            *) die "${sub}: unknown value '${token}' in ${opt} (valid: $(printf '%s' "$valid" | tr ' ' ','))" ;;
        esac
    done
    for v in $valid; do
        case ",${csv}," in *",${v},"*) result="${result} ${v}" ;; esac
    done
    printf '%s' "${result# }"
}

# Parses the --agents list $1 of subcommand $2.
parse_agents_csv() {
    parse_csv "$1" "$2" --agents "$ALL_AGENTS"
}

# Prints 1 or 0 for the value $1 of --claude=VALUE.
parse_claude_value() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        true) printf 1 ;;
        false) printf 0 ;;
        *) die "--claude takes true or false (got '$1')" ;;
    esac
}

# Prints the conventions of a skills / agents-md run: "agents" -- .agents/skills
# and AGENTS.md, read by Codex, OpenCode, Junie and other agents, always -- and
# "claude" -- .claude/skills and CLAUDE.md -- when Claude Code is on.
# $1 - --claude: 1 or 0
claude_conventions() {
    if [ "$1" = 1 ]; then printf 'agents claude'; else printf 'agents'; fi
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
  install.sh                                                  # interactive wizard
  install.sh skills     [--scope global|local] [--claude=false] # install skills into a store and link them
  install.sh agents-md  [--claude=false]                      # install project guidelines
  install.sh mcp        --servers CSV --agents CSV [--scope local|global] [--context7-key KEY]
                                                              # register MCP servers
  install.sh mcp-jetbrains | mcp-context7 | playwright --agents CSV [--scope local|global]
                                                              # register one MCP server
                                                              # (mcp-context7 also takes --context7-key)

Common options:
  --content-ref REF          Repository branch/ref to download and use. Defaults
                             to this release branch (v3). Studio passes its
                             resolved toolkit branch here.
  --source DIR               Install from a local checkout of this repository
                             instead of downloading. Skips the network. Mainly
                             for CI and offline use.
  --backup-existing-files    Rename overwritten files/dirs to <name>.bak
                             (deduped: .bak, .bak1, .bak2, ...) instead of
                             deleting them. Off by default. Skill folders
                             replaced in a project go to the project's
                             .agents/.jmix/backups/ instead, where agents do
                             not read them as skills. Project guidelines
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

skills / agents-md options:
  --claude[=true|false]  Set up Claude Code (on by default). Use --claude=false
                         to skip .claude/skills links and CLAUDE.md. The skills
                         in .agents/skills and guidelines in AGENTS.md are
                         always installed.
  --scope global|local   skills: "global" (default) links the skills into the
                         user home, "local" into the current project: there
                         the skills are kept in .agents/skills (and linked
                         into .claude/skills unless --claude=false). The .skills store
                         of earlier versions is migrated and removed.

mcp / mcp-jetbrains / mcp-context7 / playwright options:
  --agents CSV           claude, codex, opencode, junie, cline. claude also
                         sets up Claude Desktop when it is installed here.
  --scope local|global   "local" (default) writes the project files in the
                         current directory (.mcp.json, .codex/config.toml,
                         opencode.json, .junie/mcp/mcp.json); "global" writes
                         each agent's user config. Claude Desktop and Cline
                         have only a user config.
  --servers CSV          mcp: jetbrains, context7, playwright.
  --context7-key K       mcp, mcp-context7: Context7 API key; prompted when
                         missing, and "skip" leaves Context7 out. At local
                         scope the key is written into the project files: keep
                         them out of version control.

Environment:
  JMIX_IDE_MCP_PORT  Port of the IntelliJ IDEA MCP server (default 64342).
  CLINE_MCP_SETTINGS_PATH, CLINE_DATA_DIR, CLINE_DIR
                     Where Cline keeps its MCP config, read as Cline reads them
                     (default ~/.cline/data/settings/cline_mcp_settings.json).
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
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        global) printf 'global' ;;
        local) printf 'local' ;;
        *) die "$2: --scope must be 'global' or 'local' (got '$1')" ;;
    esac
}

# Relative skills dir of convention $1, rooted at $HOME (global) or the project
# dir (local).
convention_skills_dir() {
    case "$1" in
        agents) printf '.agents/skills' ;;
        claude) printf '.claude/skills' ;;
        *) die "unknown convention '$1'" ;;
    esac
}

# Earlier versions also linked the skills into .junie/skills. Junie reads
# .agents/skills now, which every run links (or which is the store), and its
# CLI reads ~/.junie/skills first, so links left there would shadow newer
# skills: the toolkit's own links are removed -- never from a .junie/skills
# that is the same dir as an agent skills dir: its links are the ones this run
# just created.
# $1 - scope root (the user home or the project dir)
remove_old_junie_skill_links() {
    local dir="$1/.junie/skills" link
    [ -d "$dir" ] || return 0
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
# symlink; an existing real dir is backed up (when --backup-existing-files, see
# skill_backup_path) or removed. Requires symlink support; fails otherwise.
create_symlink() {
    local link="$1"
    local target="$2"
    if [ -L "$link" ]; then
        rm -f "$link" || die "cannot replace symlink ${link}"
    elif [ -e "$link" ]; then
        if [ "$BACKUP_EXISTING" -eq 1 ]; then
            mv "$link" "$(skill_backup_path "$link")" || die "cannot back up ${link}"
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
    clear_dangling_symlink "$(dirname "$store_dir")"
    clear_dangling_symlink "$store_dir"
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
# Only the skills being installed are linked: the global store also keeps the
# backups that --backup-existing-files makes there.
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

# Links the store into the skills dir of every convention in $3 under root $1.
# Dirs resolving to the same physical dir are linked once.
link_store_into_agents() {
    local root="$1" store_dir="$2" conventions="$3"
    local conv agent_dir phys existed seen=" "
    for conv in $conventions; do
        agent_dir="${root}/$(convention_skills_dir "$conv")"
        existed=0
        [ -d "$agent_dir" ] && existed=1
        phys="$(prepare_agent_dir "$agent_dir")" || return 1
        case "$seen" in
            *" ${phys} "*) continue ;;
        esac
        seen="${seen}${phys} "
        # An agent dir that is the store (the local .agents/skills, or e.g.
        # .claude/skills -> ../.agents/skills) already holds the skills; links
        # there would point at themselves.
        if [ "$phys" -ef "$store_dir" ]; then
            log "  ${agent_dir} is the skills store itself; nothing to link"
            continue
        fi
        link_skills_into_dir "$phys" "$store_dir"
        emit_change "$([ "$existed" -eq 1 ] && printf updated || printf created)" dir "$agent_dir"
        log "  Linked skills into ${agent_dir}"
    done
    remove_old_junie_skill_links "$root"
}

# Sets SKILLS_ROOT, SKILLS_STORE and SKILL_BACKUP_DIR for scope $1. Local skills
# are real folders in the project's .agents/skills (.claude/skills links into
# it), and replaced ones are backed up to
# .agents/.jmix/backups, out of the dirs agents read. Global skills live in
# ~/.agents/.jmix/skills/<branch>, backed up beside themselves.
select_skills_scope() {
    if [ "$1" = local ]; then
        SKILLS_ROOT="$(pwd -P)"
        SKILLS_STORE="${SKILLS_ROOT}/.agents/skills"
        SKILL_BACKUP_DIR="${SKILLS_ROOT}/.agents/.jmix/backups"
    else
        SKILLS_ROOT="$HOME"
        SKILLS_STORE="${HOME}/.agents/.jmix/skills/${RESOLVED_VERSION_DIR}"
        SKILL_BACKUP_DIR=""
    fi
}

# Earlier versions kept local skills in <project>/.skills, linked from
# .agents/skills and .claude/skills. Run once the new store is filled and
# linked: every <project>/.*/skills dir (other agents' too) is swept of the old
# store (see relink_legacy_store_links), then .skills is emptied of its Jmix
# entries (see remove_legacy_store_entries). A .skills that is a link is the
# user's own setup: left alone. One that is an agent skills dir (e.g.
# .claude/skills -> ../.skills) is live: kept, and linked like .claude/skills
# so it does not go stale.
# $1 - project dir (physical)   $2 - store dir
migrate_legacy_local_store() {
    local root="$1" store_dir="$2" legacy="$1/.skills" dir
    [ -L "$legacy" ] && return 0
    # .[!.]* skips . and .. (bash 3.2 globs them). ponytail: only
    # <project>/.<agent>/skills dirs; add others if an agent reads one.
    for dir in "$root"/.[!.]*/skills; do
        [ "$legacy" -ef "$dir" ] || continue
        [ "$dir" -ef "$store_dir" ] || link_skills_into_dir "$(cd "$dir" && pwd -P)" "$store_dir"
        log "  Kept the old skills store ${legacy}: ${dir} links to it"
        return 0
    done
    for dir in "$root"/.[!.]*/skills; do
        [ -d "$dir" ] || continue
        relink_legacy_store_links "$dir" "$root" "$store_dir"
    done
    [ -d "$legacy" ] || return 0
    remove_legacy_store_entries "$legacy"
}

# In agent skills dir $1, links named jmix* into the old <project>/.skills are
# re-linked to the store (a skill being installed) or removed (retired skills,
# old backups), and real jmix*.bak* folders older versions left beside the
# skills move to the backups dir, where agents do not read them.
# $1 - agent skills dir   $2 - project dir (physical)   $3 - store dir
relink_legacy_store_links() {
    local dir="$1" root="$2" phys rel_store entry name target parent moved=0
    phys="$(cd "$dir" && pwd -P)" || return 0
    rel_store="$(relpath "$phys" "$(cd "$3" && pwd -P)")"
    for entry in "$phys"/jmix "$phys"/jmix-* "$phys"/jmix.*; do
        name="${entry##*/}"
        if [ ! -L "$entry" ]; then
            case "$name" in *.bak*) [ -d "$entry" ] || continue ;; *) continue ;; esac
            mv "$entry" "$(skill_backup_path "$entry")" || die "cannot back up ${entry}"
            moved=$((moved + 1))
            continue
        fi
        target="$(readlink "$entry")"
        target="${target%/}"
        case "$target" in /*) ;; *) target="${phys}/${target}" ;; esac
        parent="${target%/*}"
        # -ef also matches .skills under another spelling of the project
        # path (e.g. macOS /var -> /private/var), and a .skills now gone.
        { [ "${parent##*/}" = .skills ] && [ "${parent%/*}" -ef "$root" ]; } || continue
        if [ -d "${SOURCE_SKILLS_DIR}/${name}" ]; then
            create_symlink "$entry" "${rel_store}/${name}"
        else
            rm -f "$entry" || die "cannot remove ${entry}"
        fi
        moved=$((moved + 1))
    done
    [ "$moved" -eq 0 ] || log "  Re-linked, removed or backed up ${moved} entries of the old skills store in ${dir}"
}

# Removes the Jmix entries of the old store $1: the toolkit's skills and their
# old backups are deleted (backed up with --backup-existing-files), any other
# jmix* entry, retired or the user's own, is always backed up. $1 goes when
# nothing else is left in it.
remove_legacy_store_entries() {
    local legacy="$1" entry name backup
    for entry in "$legacy"/jmix "$legacy"/jmix-* "$legacy"/jmix.*; do
        name="${entry##*/}"
        if [ -L "$entry" ]; then
            rm -f "$entry" || die "cannot remove ${entry}"
        elif [ ! -e "$entry" ]; then
            continue
        elif [ "$BACKUP_EXISTING" -ne 1 ] && [ -d "${SOURCE_SKILLS_DIR}/${name%%.bak*}" ]; then
            rm -rf "$entry" || die "cannot remove ${entry}"
        else
            backup="$(skill_backup_path "$entry")"
            mv "$entry" "$backup" || die "cannot back up ${entry}"
            log "  Backed up ${entry} to ${backup}"
        fi
    done
    # Clutter Finder and Explorer leave is not the user's.
    rm -f "$legacy/.DS_Store" "$legacy/Thumbs.db" "$legacy/desktop.ini"
    if rmdir "$legacy" 2>/dev/null; then
        log "  Removed the old skills store ${legacy}"
    else
        log "  Kept the old skills store ${legacy}: it holds other files"
    fi
}

agent_label() {
    case "$1" in
        claude)         printf 'Claude CLI' ;;
        codex)          printf 'Codex' ;;
        opencode)       printf 'OpenCode' ;;
        junie)          printf 'Junie' ;;
        cline)          printf 'Cline' ;;
        *) printf '%s' "$1" ;;
    esac
}

guidelines_label() {
    case "$1" in
        agents) printf 'AGENTS.md (Codex, OpenCode, Junie, ...)' ;;
        claude) printf 'CLAUDE.md (Claude Code)' ;;
    esac
}

cmd_skills() {
    local claude=1
    local scope="global"

    local _argc=-1
    while [ $# -gt 0 ]; do
        [ "$#" -ne "$_argc" ] || die "argument parser made no progress near: $1"
        _argc=$#
        case "$1" in
            --claude) claude=1; shift ;;
            --claude=*) claude="$(parse_claude_value "${1#*=}")"; shift ;;
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

    local conventions
    conventions="$(claude_conventions "$claude")"
    scope="$(parse_scope "$scope" skills)"

    ensure_tarball

    select_skills_scope "$scope"
    local root="$SKILLS_ROOT" store_dir="$SKILLS_STORE"

    local store_existed=0
    [ -d "$store_dir" ] && store_existed=1

    vlog "scope=${scope} root=${root} store=${store_dir}"
    install_skills_to_store "$store_dir"
    emit_change "$([ "$store_existed" -eq 1 ] && printf updated || printf created)" dir "$store_dir"

    log ""
    log "Linking store skills into agent dirs"
    link_store_into_agents "$root" "$store_dir" "$conventions"
    if [ "$scope" = "local" ]; then
        migrate_legacy_local_store "$root" "$store_dir"
    fi

    log ""
    log "Done. Installed ${scope} skills store at ${store_dir} and linked: $(printf '%s' "$conventions" | tr ' ' ',' | sed 's/,/, /g')"
}

# =================================================================
# agents-md install (project-level)
# =================================================================

# Project guidelines file of convention $1.
convention_guidelines_file() {
    case "$1" in
        agents) printf '%s/AGENTS.md' "$(pwd -P)" ;;
        claude) printf '%s/CLAUDE.md' "$(pwd -P)" ;;
        *) die "unknown convention '$1'" ;;
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

# Installs the block for convention $1, then checks what could still hide it
# from the agents (see the helpers above).
install_guidelines_block_for() {
    local dest
    dest="$(convention_guidelines_file "$1")"
    write_guidelines_block "$1" "$dest"
    if [ "$1" = agents ]; then
        warn_if_codex_misses_block "$dest"
    fi
}

# Writes the toolkit-managed block for convention $1 into guidelines file $2.
# Four branches, in order:
#   1. no file            -> write the block, or @AGENTS.md for a new CLAUDE.md
#   2. markers present    -> replace only that region, no backup
#   3. legacy toolkit file-> back up, replace whole file
#   4. anything else      -> back up, add the block, keep everything they wrote:
#                            on top of an AGENTS.md (Codex reads only its first
#                            32 KiB), at the end of any other file
# Before 2-4, a CLAUDE.md that already gets the block through AGENTS.md (see
# claude_md_covered_by_agents_md) is skipped, and a dest that exists but is not
# a file is an error.
write_guidelines_block() {
    local conv="$1" dest="$2"
    local label dest_dir tmp backup
    label="$(guidelines_label "$conv")"

    [ -f "$SOURCE_GUIDELINES_BLOCK" ] \
        || die "guidelines-block.md not found in ${RESOLVED_VERSION_DIR}"

    dest_dir="$(dirname "$dest")"
    mkdir -p "$dest_dir" || die "cannot create directory ${dest_dir}"

    if [ ! -e "$dest" ]; then
        if [ "$conv" = claude ] && [ ! -L "$dest" ] && has_guidelines_block "${dest_dir}/AGENTS.md"; then
            printf '@AGENTS.md\n' > "$dest" || die "cannot write ${dest}"
        else
            cp "$SOURCE_GUIDELINES_BLOCK" "$dest" || die "cannot copy to ${dest}"
        fi
        log "  Installed: ${dest}"
        emit_change created file "$dest"
        log "  Project guidelines installed for ${label}"
        return 0
    fi

    [ -f "$dest" ] || die "cannot merge guidelines into ${dest}: it exists but is not a file"

    if [ "$conv" = claude ] && claude_md_covered_by_agents_md "$dest"; then
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

# Installs the block for every convention in $1 (space-separated, agents before
# claude as claude_conventions orders them, so claude_md_covered_by_agents_md
# sees AGENTS.md in its final state). $2=1 keeps going after a failed one
# (wizard).
install_guidelines_blocks() {
    local conventions="$1" lenient="${2:-0}" conv
    for conv in $conventions; do
        if [ "$lenient" -eq 1 ]; then
            install_guidelines_block_for "$conv" || true
        else
            install_guidelines_block_for "$conv"
        fi
    done
}

cmd_agents_md() {
    local claude=1

    local _argc=-1
    while [ $# -gt 0 ]; do
        [ "$#" -ne "$_argc" ] || die "argument parser made no progress near: $1"
        _argc=$#
        case "$1" in
            --claude) claude=1; shift ;;
            --claude=*) claude="$(parse_claude_value "${1#*=}")"; shift ;;
            --backup-existing-files)
                BACKUP_EXISTING=1; shift ;;
            --source)
                [ $# -ge 2 ] || die "--source requires an argument"
                SOURCE_DIR="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown argument: $1" ;;
        esac
    done

    local conventions
    conventions="$(claude_conventions "$claude")"

    log "Project guidelines target directory: $(pwd -P)"
    ensure_tarball
    install_guidelines_blocks "$conventions"
}

# =================================================================
# MCP registration (shared by mcp, mcp-jetbrains, mcp-context7, playwright)
# =================================================================
#
# Servers are written straight into each agent's config file. Local scope
# writes the project files, global scope the user files:
#
#   agent           local                  global
#   claude          .mcp.json              ~/.claude.json via `claude mcp add`
#   codex           .codex/config.toml     ${CODEX_HOME:-~/.codex}/config.toml
#   opencode        opencode.json          ${XDG_CONFIG_HOME:-~/.config}/opencode/opencode.json
#   junie           .junie/mcp/mcp.json    ${JUNIE_HOME:-~/.junie}/mcp/mcp.json
#   cline           (the global file)      ${CLINE_DIR:-~/.cline}/data/settings/cline_mcp_settings.json
#
# With claude, Claude Desktop is set up too when it is installed (see
# mcp_desktop): claude_desktop_config.json, user level only. Cline (VS Code,
# JetBrains, CLI) has no project MCP config either, so its user file is
# written whatever the scope.
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

# Prints the MCP config file of agent $1 for scope $2 (see the table above).
mcp_config_file() {
    case "$1:$2" in
        claude:local)    printf '%s/.mcp.json' "$(pwd -P)" ;;
        codex:local)     printf '%s/.codex/config.toml' "$(pwd -P)" ;;
        codex:global)    printf '%s/config.toml' "${CODEX_HOME:-${HOME}/.codex}" ;;
        opencode:local)  printf '%s/opencode.json' "$(pwd -P)" ;;
        opencode:global) printf '%s/opencode/opencode.json' "${XDG_CONFIG_HOME:-${HOME}/.config}" ;;
        junie:local)     printf '%s/.junie/mcp/mcp.json' "$(pwd -P)" ;;
        junie:global)    printf '%s/mcp/mcp.json' "${JUNIE_HOME:-${HOME}/.junie}" ;;
        # Resolved as Cline's resolveMcpSettingsPath does.
        cline:global)    printf '%s' "${CLINE_MCP_SETTINGS_PATH:-${CLINE_DATA_DIR:-${CLINE_DIR:-${HOME}/.cline}/data}/settings/cline_mcp_settings.json}" ;;
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
# result mixes url (HTTP) and command (stdio). Fails when one of those layers,
# other than the one written, defines the server with the other transport;
# they are only read, never changed.
# $1 - scope written   $2 - server name   $3 - TOML body
codex_check_layers() {
    local own cwd root dir
    own="$(mcp_config_file codex "$1")"
    cwd="$(pwd -P)" || { err "cannot determine the current directory"; return 1; }
    root="$cwd"
    while [ ! -e "$root/.git" ]; do
        if [ "$root" = / ]; then root="$cwd"; break; fi
        root="$(dirname "$root")"
    done
    codex_check_layer "$own" "$(mcp_config_file codex global)" "$2" "$3" || return 1
    dir="$cwd"
    while :; do
        codex_check_layer "$own" "${dir}/.codex/config.toml" "$2" "$3" || return 1
        [ "$dir" != "$root" ] || break
        dir="$(dirname "$dir")"
    done
}

# Fails when Codex config $2 -- unless it is $1, the file being written (also
# the user config when run from the user's home) -- defines server $3 with
# another transport than TOML body $4.
codex_check_layer() {
    local own="$1" file="$2" mine theirs
    if [ "$file" = "$own" ] || [ "$file" -ef "$own" ]; then
        return 0
    fi
    toml_set_table "$file" "mcp_servers.$3" "$4" 644 scan || return 1
    theirs="$(codex_transport "$file" "mcp_servers.$3")" || return 1
    case "$4" in url*) mine="url" ;; *) mine="command" ;; esac
    [ -n "$theirs" ] && [ "$theirs" != "$mine" ] || return 0
    if [ "$3" = jetbrains ] && [ "$JB_GUESSED" = 1 ]; then
        err "${file} defines [mcp_servers.jetbrains] with another transport, and IntelliJ IDEA is not reachable to tell which one it serves. Start it with its MCP server enabled and re-run."
    else
        err "${file} defines [mcp_servers.$3] with another transport, which Codex cannot merge with ${own}. Remove or change that table, then re-run."
    fi
    return 1
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
        log "  Skipped: 'claude' CLI not found on PATH, in ~/.local/bin or in ~/.claude/local. Install Claude Code and re-run."
        return 0
    fi
    "$cli" mcp remove --scope user "$name" >/dev/null 2>&1 || true
    "$cli" mcp add "$@" >/dev/null || { err "claude mcp add ${name} failed"; return 1; }
    log "  Registered ${name} in the Claude Code user config"
}

# Writes MCP server $3 for agent $1 at scope $2. $4 is the entry: compact JSON,
# or the TOML table body for codex. For claude at global scope the remaining
# arguments are passed to `claude mcp add` instead.
mcp_write() {
    local agent="$1" scope="$2" name="$3" entry="$4" file mode=644
    shift 4
    # Cline has only its user config (see mcp_followups).
    [ "$agent" = cline ] && scope=global
    if [ "$agent" = claude ] && [ "$scope" = global ]; then
        mcp_claude_user "$name" "$@"
        return
    fi
    # A new user config is private (it may get the Context7 key later), and so
    # is any new file that gets it now.
    if [ "$scope" = global ] || [ "$MCP_PRIVATE" = 1 ]; then
        mode=600
    fi
    file="$(mcp_config_file "$agent" "$scope")" || { err "no MCP config file for ${agent}"; return 1; }
    case "$agent" in
        codex)
            codex_check_layers "$scope" "$name" "$entry" \
                && toml_set_table "$file" "mcp_servers.${name}" "$entry" "$mode" ;;
        opencode)
            json_set_entry "$file" mcp "$name" "$entry" "$mode" ;;
        *)
            json_set_entry "$file" mcpServers "$name" "$entry" "$mode" ;;
    esac || return 1
    if [ "$MCP_PRIVATE" = 1 ] && [ "$scope" = local ]; then
        MCP_KEY_FILES="${MCP_KEY_FILES} ${file#"$(pwd -P)"/}"
    fi
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
    shift 2
    for agent in $agents; do
        log ""
        "$fn" "$agent" "$@" || rc=1
    done
    return $rc
}

# Prints what the user still has to do for the configs just written.
mcp_followups() {
    [ "$MCP_SCOPE" = local ] || return 0
    log ""
    case " $MCP_AGENTS_SEL " in *" claude "*)
        log "Claude Code asks to approve the servers in .mcp.json on its next start in this project." ;;
    esac
    case " $MCP_AGENTS_SEL " in *" codex "*)
        log "Codex reads .codex/config.toml only in trusted projects: accept its 'trust this folder' prompt. The Codex desktop app ignores project MCP servers; use --scope global for it." ;;
    esac
    case " $MCP_AGENTS_SEL " in *" cline "*)
        log "Cline has no project MCP config: it reads the user config $(mcp_config_file cline global)." ;;
    esac
    if [ -n "$MCP_KEY_FILES" ]; then
        log "The Context7 API key is now in${MCP_KEY_FILES}: keep these files out of version control."
    fi
}

# Parses the MCP subcommand options into MCP_AGENTS_SEL / MCP_SCOPE / MCP_KEY
# and, for mcp, MCP_SERVERS. $1 - subcommand name; the rest are the arguments.
parse_mcp_args() {
    local sub="$1" agents_csv="" scope="local" servers_csv=""
    shift
    MCP_KEY=""
    MCP_KEY_FILES=""
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
            --servers)
                [ "$sub" = mcp ] || die "unknown argument: $1"
                [ $# -ge 2 ] || die "--servers requires an argument"
                servers_csv="$2"; shift 2 ;;
            --context7-key)
                case "$sub" in mcp|mcp-context7) ;; *) die "unknown argument: $1" ;; esac
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
    MCP_SCOPE="$(parse_scope "$scope" "$sub")"
    if [ "$sub" = mcp ]; then
        MCP_SERVERS="$(parse_csv "$servers_csv" "$sub" --servers "$MCP_SERVERS_ALL")"
    fi
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

# $1 - agent   $2 - scope
install_jetbrains_for() {
    local agent="$1" scope="$2" base="http://127.0.0.1:${JB_PORT}"
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
            claude)   mcp_write claude "$scope" jetbrains "{\"type\":\"http\",\"url\":\"${base}/stream\"}" \
                          --scope user --transport http jetbrains "${base}/stream" ;;
            codex)    mcp_write codex "$scope" jetbrains "url = \"${base}/stream\"" ;;
            opencode) mcp_write opencode "$scope" jetbrains "{\"type\":\"remote\",\"url\":\"${base}/stream\",\"enabled\":true}" ;;
            cline)    mcp_write cline "$scope" jetbrains "{\"type\":\"streamableHttp\",\"url\":\"${base}/stream\"}" ;;
        esac || rc=1
    else
        case "$agent" in
            claude)   mcp_write claude "$scope" jetbrains "{\"type\":\"sse\",\"url\":\"${base}/sse\"}" \
                          --scope user --transport sse jetbrains "${base}/sse" ;;
            # Codex has no SSE transport.
            codex)    mcp_write codex "$scope" jetbrains "command = \"npx\"
args = [\"-y\", \"mcp-remote\", \"${base}/sse\", \"--transport\", \"sse-only\"]
startup_timeout_sec = 60" ;;
            opencode) mcp_write opencode "$scope" jetbrains "{\"type\":\"remote\",\"url\":\"${base}/sse\",\"enabled\":true}" ;;
            cline)    mcp_write cline "$scope" jetbrains "{\"type\":\"sse\",\"url\":\"${base}/sse\"}" ;;
        esac || rc=1
    fi
    # Claude Desktop has no HTTP transport for local servers: always the bridge.
    if [ "$agent" = claude ]; then
        mcp_desktop jetbrains "$bridge_json" || rc=1
    fi
    return $rc
}

# Registers JetBrains MCP for MCP_AGENTS_SEL at MCP_SCOPE.
mcp_jetbrains_step() {
    local rc=0
    log ""
    detect_jetbrains_transport
    mcp_for_agents install_jetbrains_for "$MCP_AGENTS_SEL" "$MCP_SCOPE" || rc=1
    if desktop_selected; then
        warn_if_no_npx "Claude Desktop's JetBrains MCP bridge"
    elif [ "$JB_TRANSPORT" = sse ]; then
        case " $MCP_AGENTS_SEL " in *" codex "*) warn_if_no_npx "Codex's JetBrains MCP bridge" ;; esac
    fi
    return $rc
}

cmd_mcp_jetbrains() {
    parse_mcp_args mcp-jetbrains "$@"
    local rc=0
    mcp_jetbrains_step || rc=1
    mcp_followups
    return $rc
}

# =================================================================
# MCP install - Context7
# =================================================================

# Fails for an empty key or one that would need escaping: the key is spliced
# into JSON, TOML and an HTTP header as is.
context7_key_ok() {
    case "$1" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
}

# $1 - agent   $2 - scope   $3 - API key
install_context7_for() {
    local agent="$1" scope="$2" key="$3"
    local http_json="{\"type\":\"http\",\"url\":\"${CONTEXT7_URL}\",\"headers\":{\"Authorization\":\"Bearer ${key}\"}}"
    local stdio_json="{\"command\":\"npx\",\"args\":[\"-y\",\"@upstash/context7-mcp\"],\"env\":{\"CONTEXT7_API_KEY\":\"${key}\"}}"
    log "[Context7 MCP] $(agent_label "$agent")"
    case "$agent" in
        claude)
            local rc=0
            mcp_write claude "$scope" context7 "$http_json" \
                --scope user --transport http context7 "$CONTEXT7_URL" --header "Authorization: Bearer ${key}" || rc=1
            mcp_desktop context7 "$stdio_json" || rc=1
            return $rc ;;
        codex)    mcp_write codex "$scope" context7 "url = \"${CONTEXT7_URL}\"
http_headers = { Authorization = \"Bearer ${key}\" }" ;;
        opencode) mcp_write opencode "$scope" context7 "{\"type\":\"remote\",\"url\":\"${CONTEXT7_URL}\",\"headers\":{\"Authorization\":\"Bearer ${key}\"},\"enabled\":true}" ;;
        cline)    mcp_write cline "$scope" context7 "{\"type\":\"streamableHttp\",\"url\":\"${CONTEXT7_URL}\",\"headers\":{\"Authorization\":\"Bearer ${key}\"}}" ;;
        # Junie (and Claude Desktop above): stdio, the key in the environment, not in argv.
        *)        mcp_write "$agent" "$scope" context7 "$stdio_json" ;;
    esac
}

# Registers Context7 for MCP_AGENTS_SEL at MCP_SCOPE with key MCP_KEY, asking
# for it when it is empty; "skip" skips the step (Studio's MCP step has to pass
# a value).
mcp_context7_step() {
    local key="$MCP_KEY" rc=0
    log ""
    if [ "$key" = skip ]; then
        log "[Context7 MCP] Skipped: no API key given."
        return 0
    fi
    if [ -z "$key" ]; then
        key="$(prompt 'Context7 API key' '')"
        [ -n "$key" ] || { err "Context7 API key is required"; return 1; }
    fi
    context7_key_ok "$key" || { err "Context7 API key may contain only letters, digits, '.', '_' and '-'"; return 1; }
    MCP_PRIVATE=1
    mcp_for_agents install_context7_for "$MCP_AGENTS_SEL" "$MCP_SCOPE" "$key" || rc=1
    MCP_PRIVATE=0
    case " $MCP_AGENTS_SEL " in
        *" junie "*) warn_if_no_npx "Context7 for Junie" ;;
        *) desktop_selected && warn_if_no_npx "Context7 for Claude Desktop" ;;
    esac
    return $rc
}

cmd_mcp_context7() {
    parse_mcp_args mcp-context7 "$@"
    local rc=0
    mcp_context7_step || rc=1
    mcp_followups
    return $rc
}

# =================================================================
# MCP install - Playwright
# =================================================================

# $1 - agent   $2 - scope
install_playwright_for() {
    local agent="$1" scope="$2"
    log "[Playwright MCP] $(agent_label "$agent")"
    local stdio_json="{\"command\":\"npx\",\"args\":[\"-y\",\"${PLAYWRIGHT_MCP_PKG}\"]}"
    case "$agent" in
        claude)
            local rc=0
            mcp_write claude "$scope" playwright "{\"type\":\"stdio\",\"command\":\"npx\",\"args\":[\"-y\",\"${PLAYWRIGHT_MCP_PKG}\"]}" \
                --scope user playwright -- npx -y "$PLAYWRIGHT_MCP_PKG" || rc=1
            mcp_desktop playwright "$stdio_json" || rc=1
            return $rc ;;
        # The first npx download can outlast Codex's default startup timeout.
        codex)    mcp_write codex "$scope" playwright "command = \"npx\"
args = [\"-y\", \"${PLAYWRIGHT_MCP_PKG}\"]
startup_timeout_sec = 60" ;;
        opencode) mcp_write opencode "$scope" playwright "{\"type\":\"local\",\"command\":[\"npx\",\"-y\",\"${PLAYWRIGHT_MCP_PKG}\"],\"enabled\":true}" ;;
        *)        mcp_write "$agent" "$scope" playwright "$stdio_json" ;;
    esac
}

# Registers Playwright MCP for MCP_AGENTS_SEL at MCP_SCOPE.
mcp_playwright_step() {
    local rc=0
    log ""
    mcp_for_agents install_playwright_for "$MCP_AGENTS_SEL" "$MCP_SCOPE" || rc=1
    warn_if_no_npx "The Playwright MCP server"
    return $rc
}

cmd_playwright() {
    parse_mcp_args playwright "$@"
    local rc=0
    mcp_playwright_step || rc=1
    mcp_followups
    return $rc
}

# =================================================================
# MCP install - several servers in one step (Studio's MCP step)
# =================================================================

cmd_mcp() {
    parse_mcp_args mcp "$@"
    local rc=0 server
    for server in $MCP_SERVERS; do
        case "$server" in
            jetbrains)  mcp_jetbrains_step || rc=1 ;;
            context7)   mcp_context7_step || rc=1 ;;
            playwright) mcp_playwright_step || rc=1 ;;
        esac
    done
    mcp_followups
    return $rc
}

# =================================================================
# Wizard
# =================================================================

server_label() {
    case "$1" in
        jetbrains)  printf 'JetBrains (code insight from IntelliJ IDEA)' ;;
        context7)   printf 'Context7 (library docs, needs an API key)' ;;
        playwright) printf 'Playwright (browser automation)' ;;
    esac
}

# Prints the options of space-separated list $4 (shown through label function
# $3) that the answer picks, in $4's order, or "skip". The answer is a (all),
# s (skip) or option numbers separated by commas; $1 is the default answer.
wizard_pick() {
    local default_choice="$1" title="$2" label_fn="$3" options="$4"
    local opt i=1 answer nums picked=""
    {
        log ""
        log "$title"
        printf '  a) All\n'
        for opt in $options; do
            printf '  %d) %s\n' "$i" "$("$label_fn" "$opt")"
            i=$((i + 1))
        done
        printf '  s) Skip\n'
    } >&2
    answer="$(prompt 'Choice (a, s, or numbers like 1,3)' "$default_choice")"
    case "$answer" in
        s|S|skip|SKIP) printf 'skip'; return 0 ;;
        a|A|all|ALL) printf '%s' "$options"; return 0 ;;
    esac
    nums=",$(printf '%s' "$answer" | tr -d ' '),"
    case "$nums" in *[!0-9,]*) nums="" ;; esac
    i=1
    for opt in $options; do
        case "$nums" in *",${i},"*) picked="${picked} ${opt}" ;; esac
        i=$((i + 1))
    done
    if [ -z "$picked" ]; then
        log "Unrecognized choice '${answer}'. Skipping." >&2
        printf 'skip'
        return 0
    fi
    printf '%s' "${picked# }"
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
    local summary_mcp="skipped"
    local sel scope="local" claude_default="y"

    # Step 1: skills, into .agents/skills and, for Claude Code, .claude/skills.
    log ""
    if prompt_yes_no '[1/3] Install Jmix skills into .agents/skills?' y; then
        case "$(prompt 'Install scope: (l)ocal project dir or (g)lobal user home' 'l')" in
            g|G|global|GLOBAL) scope="global" ;;
        esac
        sel="agents"
        if prompt_yes_no 'For Claude Code too (links in .claude/skills)?' y; then
            sel="agents claude"
        else
            claude_default="n"
        fi
        ensure_tarball
        select_skills_scope "$scope"
        install_skills_to_store "$SKILLS_STORE" || true
        # The old store goes only once the new layout is linked.
        if link_store_into_agents "$SKILLS_ROOT" "$SKILLS_STORE" "$sel" && [ "$scope" = "local" ]; then
            migrate_legacy_local_store "$SKILLS_ROOT" "$SKILLS_STORE" || true
        fi
        summary_skills="${sel// /, } (${scope})"
    fi

    # Step 2: agents-md, into AGENTS.md and, for Claude Code, CLAUDE.md. The
    # Claude Code answer defaults to the one given for the skills.
    log ""
    if prompt_yes_no "[2/3] Merge Jmix coding guidelines into AGENTS.md in $(pwd -P)?" y; then
        sel="agents"
        if prompt_yes_no 'For Claude Code too (CLAUDE.md)?' "$claude_default"; then
            sel="agents claude"
        fi
        ensure_tarball
        install_guidelines_blocks "$sel" 1
        summary_guidelines="${sel// /, }"
    fi

    # Step 3: MCP servers. cmd_mcp's only exits are argument errors, which
    # cannot happen with the values passed here. The scope defaults to the one
    # chosen for the skills.
    local servers agents="skip" key="" scope_mcp="local"
    servers="$(wizard_pick skip '[3/3] Connect agents to MCP servers:' server_label "$MCP_SERVERS_ALL")"
    if [ "$servers" != "skip" ]; then
        # All but Cline by default: its config is a user file whatever the scope.
        agents="$(wizard_pick 1,2,3,4 'For the agents:' agent_label "$ALL_AGENTS")"
    fi
    if [ "$agents" != "skip" ]; then
        case "$(prompt 'Register in: (l)ocal project config or (g)lobal user config' "$(printf '%.1s' "$scope")")" in
            g|G|global|GLOBAL) scope_mcp="global" ;;
        esac
        case " $servers " in *" context7 "*)
            key="$(prompt 'Context7 API key (empty to skip Context7)' '')" ;;
        esac
        cmd_mcp --servers "$(printf '%s' "$servers" | tr ' ' ',')" --agents "$(printf '%s' "$agents" | tr ' ' ',')" \
            --scope "$scope_mcp" --context7-key "${key:-skip}" || true
        summary_mcp="${servers} for ${agents} (${scope_mcp})"
    fi

    log ""
    log "=== Setup complete ==="
    log "  Skills:      ${summary_skills}"
    log "  Guidelines:  ${summary_guidelines}"
    log "  MCP:         ${summary_mcp}"
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
    mcp)           shift; cmd_mcp "$@" ;;
    mcp-jetbrains) shift; cmd_mcp_jetbrains "$@" ;;
    mcp-context7)  shift; cmd_mcp_context7 "$@" ;;
    playwright)    shift; cmd_playwright "$@" ;;
    -h|--help)     usage ;;
    --*)           cmd_wizard "$@" ;;
    *)             die "unknown subcommand: $1" ;;
esac
