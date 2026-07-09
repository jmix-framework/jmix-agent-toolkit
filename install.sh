#!/usr/bin/env bash
# Jmix AI Agents Toolkit installer.
#
# Default (no subcommand) launches an interactive wizard that guides through:
#   1. Installing Jmix skills (globally or into the project) for one or all agents.
#   2. Adding project-level guidelines (CLAUDE.md / AGENTS.md / .junie/guidelines.md).
#   3. Registering the JetBrains MCP server with the agent.
#   4. Registering the Context7 MCP server with the agent.
#   5. Installing Playwright testing skills (requires npx).
#
# Subcommands are available for non-interactive use; see `install.sh --help`.

set -euo pipefail

REPO_OWNER="jmix-framework"
REPO_NAME="jmix-agent-guidelines"

# Global state populated by ensure_tarball()
STAGING=""
# Temp dir for the Playwright install; global so the EXIT trap can clean it
# after cmd_playwright() returns (function locals are out of scope by then).
PW_STAGING=""
EXTRACTED_DIR=""
SOURCE_SKILLS_DIR=""
SOURCE_AGENTS_MD=""
RESOLVED_VERSION_DIR=""
TARBALL_READY=0

# Branch identity: this script lives on the CONTENT_REF branch and installs that
# branch's content/. Set per branch when cutting a new version (see MAINTAINING.md).
CONTENT_REF="v2"
SOURCE_DIR=""
BACKUP_EXISTING=0
VERBOSE=0

ALL_AGENTS="claude codex opencode junie"
JETBRAINS_AGENTS="claude codex opencode junie"
CONTEXT7_AGENTS="claude codex opencode junie"

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

# Ensures npx (Node.js) is on PATH. When missing, prints per-OS install guidance
# and exits (no automatic runtime install).
require_npx() {
    command -v npx >/dev/null 2>&1 && return 0
    err "npx (Node.js) is required for the Playwright step but was not found on PATH."
    err "Install Node.js (includes npx), then re-run:"
    case "$(uname -s 2>/dev/null)" in
        Darwin) err "  macOS:  brew install node    (or download from https://nodejs.org)" ;;
        Linux)  err "  Linux:  install via your package manager (e.g. 'sudo apt install nodejs npm') or download from https://nodejs.org" ;;
        *)      err "  See https://nodejs.org/en/download" ;;
    esac
    exit 1
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
# (moved aside to a deduped <dest>.bak[N]) when $force_backup=1 or
# BACKUP_EXISTING=1; otherwise it is deleted. Prints a per-item log line.
# $1 - src path (file or dir)
# $2 - dest path
# $3 - short label shown in the log line
# $4 - force_backup: 1 to always back up regardless of --backup-existing-files
#      (used for guidelines files); defaults to 0
write_dest() {
    local src="$1"
    local dest="$2"
    local label="$3"
    local force_backup="${4:-0}"
    local existed=0
    [ -e "$dest" ] && existed=1
    local backup_info=""
    if [ "$existed" -eq 1 ]; then
        if [ "$force_backup" -eq 1 ] || [ "$BACKUP_EXISTING" -eq 1 ]; then
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
parse_agents_csv() {
    local csv="$1"
    local subcommand="$2"
    if [ -z "$csv" ]; then
        die "${subcommand}: --agents is required (e.g. --agents claude,codex)"
    fi
    local result=""
    local token
    for token in $(printf '%s' "$csv" | tr ',' ' ' | tr -s ' ' ' '); do
        case "$token" in
            claude|codex|opencode|junie) result="${result} ${token}" ;;
            "") ;;
            *) die "unknown agent in --agents: '$token'" ;;
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
  install.sh mcp-jetbrains [options]                             # register JetBrains MCP
  install.sh mcp-context7  [options] [--context7-key KEY]        # register Context7 MCP
  install.sh playwright    [options]                             # install Playwright

Common options:
  --source DIR               Install from a local checkout of this repository
                             instead of downloading. Skips the network. Mainly
                             for CI and offline use.
  --agents CSV               Comma-separated agent list. Accepts a single value
                             too (e.g. "claude" or "claude,codex"). Required by
                             every subcommand. Valid values:
                             claude, codex, opencode, junie.
  --backup-existing-files    Rename overwritten files/dirs to <name>.bak
                             (deduped: .bak, .bak1, .bak2, ...) instead of
                             deleting them. Off by default. Guidelines files
                             (CLAUDE.md / AGENTS.md / guidelines.md) are always
                             backed up regardless of this flag.
  --verbose, --debug         Print extra diagnostic output (OS, PATH, resolved
                             paths, tool versions) to help troubleshoot problems.
  -h, --help                 Show this help.

skills options:
  --scope global|local   Where to install skills. "global" (default) writes to
                         the per-agent user-home dir; "local" writes to the
                         matching dir under the current project (e.g.
                         ./.claude/skills).

mcp-context7 options:
  --context7-key K   Context7 API key. Prompted interactively when missing.

playwright options:
  (uses common --agents flag; requires `npx` (Node.js) on PATH)
EOF
}

# =================================================================
# Tarball download
# =================================================================

# Downloads and extracts the tarball, locates the content/ folder, and populates
# SOURCE_SKILLS_DIR / SOURCE_AGENTS_MD / RESOLVED_VERSION_DIR. Idempotent.
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
    SOURCE_AGENTS_MD="${content_dir}/AGENTS.md"

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
# $1 - raw scope string (may be empty -> defaults to global)
parse_scope() {
    case "${1:-global}" in
        global|local) printf '%s' "${1:-global}" ;;
        *) die "skills: --scope must be 'global' or 'local' (got '$1')" ;;
    esac
}

# Relative skills dir each agent reads, used as a whole-dir symlink to the store.
# claude -> .claude/skills ; codex & opencode -> .agents/skills (open standard) ;
# junie -> .junie/skills. Rooted at $HOME (global) or the project dir (local).
agent_symlink_rel() {
    case "$1" in
        claude)            printf '.claude/skills' ;;
        codex|opencode)    printf '.agents/skills' ;;
        junie)             printf '.junie/skills' ;;
        *) die "unknown agent '$1'" ;;
    esac
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
        base="$(dirname "$base")"
        up="../$up"
    done
    if [ "$target" = "$base" ]; then
        printf '%s' "${up:-.}"
    else
        printf '%s%s' "$up" "${target#"$base"/}"
    fi
}

# Per-skill symlinks: link each store skill folder into the agent skills dir,
# so Jmix skills coexist with other skills already present there. The link target
# is relative to the agent dir (see relpath) so links stay valid after a clone.
# $1 - agent skills dir (kept as a real dir)
# $2 - store dir holding the skill folders
link_skills_into_dir() {
    local agent_dir="$1"
    local store_dir="$2"
    # Clear a broken-symlink agent base/dir (e.g. ~/.junie -> missing) so mkdir works.
    clear_dangling_symlink "$(dirname "$agent_dir")"
    clear_dangling_symlink "$agent_dir"
    mkdir -p "$agent_dir" || die "cannot create ${agent_dir}"
    local rel_store skill name
    rel_store="$(relpath "$agent_dir" "$store_dir")"
    for skill in "$store_dir"/*/; do
        [ -d "$skill" ] || continue
        name="$(basename "$skill")"
        create_symlink "${agent_dir}/${name}" "${rel_store}/${name}"
    done
}

agent_label() {
    case "$1" in
        claude)   printf 'Claude CLI' ;;
        codex)    printf 'Codex' ;;
        opencode) printf 'OpenCode' ;;
        junie)    printf 'Junie' ;;
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
    scope="$(parse_scope "$scope")"

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
    local agent rel agent_dir seen=" "
    for agent in $agents; do
        rel="$(agent_symlink_rel "$agent")"
        case "$seen" in
            *" ${rel} "*) continue ;;
        esac
        seen="${seen}${rel} "
        agent_dir="${root}/${rel}"
        local agent_dir_existed=0
        [ -d "$agent_dir" ] && agent_dir_existed=1
        link_skills_into_dir "$agent_dir" "$store_dir"
        emit_change "$([ "$agent_dir_existed" -eq 1 ] && printf updated || printf created)" dir "$agent_dir"
        log "  Linked skills into ${agent_dir}"
    done

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
        claude)   printf '%s/CLAUDE.md' "$pwd_" ;;
        codex)    printf '%s/AGENTS.md' "$pwd_" ;;
        opencode) printf '%s/AGENTS.md' "$pwd_" ;;
        junie)    printf '%s/.junie/guidelines.md' "$pwd_" ;;
        *) die "unknown agent '$1'" ;;
    esac
}

install_agents_md_for() {
    local agent="$1"
    local dest
    dest="$(agents_md_dest_for_agent "$agent")"
    local label
    label="$(agent_label "$agent")"

    [ -f "$SOURCE_AGENTS_MD" ] || die "AGENTS.md not found in ${RESOLVED_VERSION_DIR}"

    local dest_dir
    dest_dir="$(dirname "$dest")"
    mkdir -p "$dest_dir" || die "cannot create directory ${dest_dir}"

    local dest_existed=0
    [ -e "$dest" ] && dest_existed=1
    # Guidelines are always backed up on overwrite, regardless of
    # --backup-existing-files (issue #17).
    write_dest "$SOURCE_AGENTS_MD" "$dest" "$dest" 1
    emit_change "$([ "$dest_existed" -eq 1 ] && printf updated || printf created)" file "$dest"
    log "  Project guidelines installed for ${label}"
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

    local agent
    for agent in $agents; do
        install_agents_md_for "$agent"
    done
}

# =================================================================
# MCP install - JetBrains
# =================================================================

# Registers a user-scope Claude MCP server idempotently. `claude mcp add` exits
# non-zero and writes "already exists in user config" to stderr when the name is
# already present, which Studio treats as a failed wizard step. Removing any
# existing entry first (discarding the harmless "not found" output) makes a re-run
# succeed cleanly. Usage: add_claude_user_mcp <name> <args-after-"mcp add"...>
add_claude_user_mcp() {
    local name="$1"; shift
    claude mcp remove --scope user "$name" >/dev/null 2>&1 || true
    claude mcp add "$@"
}

mcp_jetbrains_for_claude() {
    require_tool claude
    log "Adding JetBrains MCP for Claude CLI..."
    add_claude_user_mcp jetbrains --transport sse jetbrains --scope user http://localhost:64342/sse
}

mcp_jetbrains_for_codex() {
    require_tool codex
    log "Adding JetBrains MCP for Codex (Streamable HTTP; requires IntelliJ 2026.1+)..."
    log "For older IntelliJ versions, follow the STDIO setup in the README manually."
    codex mcp add jetbrains --url http://localhost:64342/stream
}

mcp_jetbrains_for_opencode() {
    local config_dir="${HOME}/.config/opencode"
    local config_file="${config_dir}/opencode.json"
    mkdir -p "$config_dir"
    [ -f "$config_file" ] || echo '{}' > "$config_file"

    if ! command -v jq >/dev/null 2>&1; then
        log "OpenCode requires jq to edit ${config_file}. Add this block manually:"
        cat <<'EOF'
  "mcp": {
    "jetbrains": {
      "type": "remote",
      "url": "http://localhost:64342/sse",
      "enabled": true
    }
  }
EOF
        return 1
    fi

    local tmp
    tmp="$(mktemp)"
    jq '.mcp = (.mcp // {}) | .mcp.jetbrains = {"type":"remote","url":"http://localhost:64342/sse","enabled":true}' "$config_file" > "$tmp"
    mv "$tmp" "$config_file"
    emit_change updated file "$config_file"
    log "Updated ${config_file} with JetBrains MCP entry."
}

mcp_jetbrains_for_junie() {
    log "Junie runs inside IntelliJ and already has native IDE access. No JetBrains MCP needed."
}

install_jetbrains_for() {
    local agent="$1"
    log ""
    log "[JetBrains MCP] $(agent_label "$agent")"
    case "$agent" in
        claude)   mcp_jetbrains_for_claude ;;
        codex)    mcp_jetbrains_for_codex ;;
        opencode) mcp_jetbrains_for_opencode ;;
        junie)    mcp_jetbrains_for_junie ;;
        *) die "unknown agent '$1'" ;;
    esac
}

cmd_mcp_jetbrains() {
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
            -h|--help) usage; exit 0 ;;
            *) die "unknown argument: $1" ;;
        esac
    done

    local agents
    agents="$(parse_agents_csv "$agents_csv" "mcp-jetbrains")"

    local agent rc=0
    for agent in $agents; do
        install_jetbrains_for "$agent" || rc=1
    done
    return $rc
}

# =================================================================
# MCP install - Context7
# =================================================================

mcp_context7_for_claude() {
    local key="$1"
    require_tool claude
    log "Adding Context7 MCP for Claude CLI..."
    add_claude_user_mcp context7 context7 --scope user -- npx -y @upstash/context7-mcp --api-key "$key"
}

mcp_context7_for_codex() {
    local key="$1"
    require_tool codex
    log "Adding Context7 MCP for Codex..."
    codex mcp add context7 -- npx -y @upstash/context7-mcp --api-key "$key"
}

mcp_context7_for_opencode() {
    local key="$1"
    local config_dir="${HOME}/.config/opencode"
    local config_file="${config_dir}/opencode.json"
    mkdir -p "$config_dir"
    [ -f "$config_file" ] || echo '{}' > "$config_file"

    if ! command -v jq >/dev/null 2>&1; then
        log "OpenCode requires jq to edit ${config_file}. Add this block manually:"
        cat <<EOF
  "mcp": {
    "context7": {
      "type": "local",
      "command": ["npx", "-y", "@upstash/context7-mcp", "--api-key", "${key}"],
      "enabled": true
    }
  }
EOF
        return 1
    fi

    local tmp
    tmp="$(mktemp)"
    jq --arg key "$key" '.mcp = (.mcp // {}) | .mcp.context7 = {"type":"local","command":["npx","-y","@upstash/context7-mcp","--api-key",$key],"enabled":true}' "$config_file" > "$tmp"
    mv "$tmp" "$config_file"
    emit_change updated file "$config_file"
    log "Updated ${config_file} with Context7 MCP entry."
}

mcp_context7_for_junie() {
    local key="$1"
    log "Junie does not support automated MCP setup."
    log "Open IntelliJ Settings -> Tools -> Junie -> MCP Settings, click Add, then paste:"
    cat <<EOF
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp", "--api-key", "${key}"]
    }
  }
}
EOF
}

install_context7_for() {
    local agent="$1"
    local key="$2"
    log ""
    log "[Context7 MCP] $(agent_label "$agent")"
    case "$agent" in
        claude)   mcp_context7_for_claude "$key" ;;
        codex)    mcp_context7_for_codex "$key" ;;
        opencode) mcp_context7_for_opencode "$key" ;;
        junie)    mcp_context7_for_junie "$key" ;;
        *) die "unknown agent '$1'" ;;
    esac
}

cmd_mcp_context7() {
    local agents_csv=""
    local key=""

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
            --context7-key)
                [ $# -ge 2 ] || die "--context7-key requires an argument"
                key="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown argument: $1" ;;
        esac
    done

    local agents
    agents="$(parse_agents_csv "$agents_csv" "mcp-context7")"

    if [ -z "$key" ]; then
        key="$(prompt 'Context7 API key' '')"
        [ -n "$key" ] || die "Context7 API key is required"
    fi

    local agent rc=0
    for agent in $agents; do
        install_context7_for "$agent" "$key" || rc=1
    done
    return $rc
}

# =================================================================
# Playwright install (npx @playwright/cli)
# =================================================================

cmd_playwright() {
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
            -h|--help) usage; exit 0 ;;
            *) die "unknown argument: $1" ;;
        esac
    done

    local agents
    agents="$(parse_agents_csv "$agents_csv" "playwright")"

    require_npx

    # Playwright skills always install globally. Mirror the Jmix model: copy the
    # skills into a canonical store, then per-skill symlink them into each agent
    # skills dir so they coexist with other skills already present there.
    local root="${HOME}"
    local store_dir="${HOME}/.agents/.playwright/skills"
    local store_existed=0
    [ -d "$store_dir" ] && store_existed=1

    # @playwright/cli install --skills writes to <cwd>/.claude/skills/<skill>.
    # Run it inside a private staging dir so nothing leaks into the project or a
    # real agent dir, then copy the produced skill folders into the store.
    PW_STAGING="$(mktemp -d 2>/dev/null || mktemp -d -t jmix-playwright)" \
        || die "cannot create temp dir for Playwright install"
    trap 'rm -rf ${PW_STAGING:+"$PW_STAGING"} ${STAGING:+"$STAGING"}' INT TERM EXIT

    log "Installing Playwright skills via npx (@playwright/cli)..."
    ( cd "$PW_STAGING" && npx -y @playwright/cli@latest install --skills ) \
        || die "@playwright/cli install --skills failed"

    local produced="${PW_STAGING}/.claude/skills"
    [ -d "$produced" ] || die "@playwright/cli produced no skills under ${produced}"

    log ""
    log "Installing Playwright skills into store ${store_dir}"
    mkdir -p "$store_dir" || die "cannot create store ${store_dir}"
    local skill name dest count=0
    for skill in "$produced"/*/; do
        [ -d "$skill" ] || continue
        name="$(basename "$skill")"
        dest="${store_dir}/${name}"
        write_dest "$skill" "$dest" "$name"
        count=$((count + 1))
    done
    [ "$count" -gt 0 ] || die "no Playwright skill folders found under ${produced}"
    emit_change "$([ "$store_existed" -eq 1 ] && printf updated || printf created)" dir "$store_dir"

    log ""
    log "Linking store skills into agent dirs"
    local agent rel agent_dir seen=" "
    for agent in $agents; do
        rel="$(agent_symlink_rel "$agent")"
        case "$seen" in
            *" ${rel} "*) continue ;;
        esac
        seen="${seen}${rel} "
        agent_dir="${root}/${rel}"
        local agent_dir_existed=0
        [ -d "$agent_dir" ] && agent_dir_existed=1
        link_skills_into_dir "$agent_dir" "$store_dir"
        emit_change "$([ "$agent_dir_existed" -eq 1 ] && printf updated || printf created)" dir "$agent_dir"
        log "  Linked skills into ${agent_dir}"
    done

    log ""
    log "Done. Installed Playwright skills store at ${store_dir} and linked: $(printf '%s' "$agents" | tr ' ' ',' | sed 's/,/, /g')"
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
        local agent rel agent_dir seen=" "
        for agent in $sel; do
            rel="$(agent_symlink_rel "$agent")"
            case "$seen" in *" ${rel} "*) continue ;; esac
            seen="${seen}${rel} "
            agent_dir="${root}/${rel}"
            link_skills_into_dir "$agent_dir" "$store_dir" || true
        done
        summary_skills="$sel (${scope})"
    fi

    # Step 2: agents-md
    sel="$(wizard_pick_agent all '[2/5] Add Jmix coding guidelines to this directory?' "$ALL_AGENTS")"
    if [ "$sel" != "skip" ]; then
        if prompt_yes_no "Target directory: $(pwd -P). Proceed?" "y"; then
            ensure_tarball
            local agent
            for agent in $sel; do
                install_agents_md_for "$agent" || true
            done
            summary_guidelines="$sel"
        else
            summary_guidelines="skipped (declined)"
        fi
    fi

    # Step 3: JetBrains MCP
    sel="$(wizard_pick_agent skip '[3/5] Connect agent to IntelliJ IDEA via JetBrains MCP?' "$JETBRAINS_AGENTS")"
    if [ "$sel" != "skip" ]; then
        local agent
        for agent in $sel; do
            install_jetbrains_for "$agent" || true
        done
        summary_jetbrains="$sel"
    fi

    # Step 4: Context7 MCP
    sel="$(wizard_pick_agent skip '[4/5] Connect agent to library docs via Context7 MCP?' "$CONTEXT7_AGENTS")"
    if [ "$sel" != "skip" ]; then
        local key
        key="$(prompt 'Context7 API key' '')"
        if [ -n "$key" ]; then
            local agent
            for agent in $sel; do
                install_context7_for "$agent" "$key" || true
            done
            summary_context7="$sel"
        else
            log "API key not provided, skipping Context7 setup."
            summary_context7="skipped (no key)"
        fi
    fi

    # Step 5: Playwright
    sel="$(wizard_pick_agent skip '[5/5] Install Playwright? (requires npx)' "$ALL_AGENTS")"
    if [ "$sel" != "skip" ]; then
        if ! command -v npx >/dev/null 2>&1; then
            # Pre-check npx so the wizard skips gracefully. cmd_playwright -> require_npx
            # would otherwise `exit 1` (not catchable by `|| true`) and abort the summary.
            log "Skipping Playwright: npx (Node.js) not found on PATH."
            summary_playwright="skipped (no npx)"
        else
            local pw_csv
            pw_csv="$(printf '%s' "$sel" | tr ' ' ',' | sed 's/^,//;s/,$//')"
            cmd_playwright --agents "$pw_csv" || true
            summary_playwright="$sel"
        fi
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

# Pull global --verbose/--debug out of the args so every subcommand benefits.
_args=()
for _a in "$@"; do
    case "$_a" in
        --verbose|--debug) VERBOSE=1 ;;
        *) _args+=("$_a") ;;
    esac
done
set -- ${_args[@]+"${_args[@]}"}
debug_env

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
