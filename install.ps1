<#
.SYNOPSIS
    Jmix AI Agents Toolkit installer.

.DESCRIPTION
    Default invocation (no subcommand) launches an interactive wizard that
    guides through:
      1. Installing Jmix skills (globally or into the project) for the chosen
         conventions (.agents/skills, .claude/skills).
      2. Adding project-level guidelines (AGENTS.md / CLAUDE.md).
      3. Registering MCP servers (JetBrains, Context7, Playwright) with the agents.

    Subcommands are available for non-interactive use:
      install.ps1 skills     -Conventions CSV [-Scope global|local]
                             Installs skills into a canonical store once, then links
                             them into the skills dir of each convention. Local
                             skills are kept in the project's .agents/skills (also
                             when only claude is chosen) and linked into
                             .claude/skills; an old .skills store is migrated and
                             removed.
      install.ps1 agents-md  -Conventions CSV
      install.ps1 mcp        -Servers CSV -Agents CSV [-Scope local|global] [-Context7Key KEY]
      install.ps1 mcp-jetbrains | mcp-context7 | playwright -Agents CSV [-Scope local|global]
                             (mcp-context7 also takes -Context7Key)

    MCP servers are written straight into each agent's config file; no agent
    CLI is needed except for Claude CLI at user level (`claude mcp add`).

    Add -BackupExistingFiles to any subcommand to rename overwritten files/dirs
    to <name>.bak (deduped: .bak, .bak1, .bak2, ...) instead of deleting them.
    Replaced local skill folders are moved to the project's
    .agents/.jmix/backups/ instead, out of the dirs the agents read skills from.
    Project guidelines (CLAUDE.md / AGENTS.md) are merged rather than
    overwritten and are not covered by this switch: a backup is made only when
    the toolkit rewrites content it does not own -- replacing a guidelines file
    an older toolkit version installed, or adding the block to your own file.
    Replacing only the marked region never makes a backup, and a file that is
    already up to date is left untouched.

.PARAMETER Subcommand
    Optional subcommand. When omitted, the interactive wizard is started.

.PARAMETER Source
    Install from a local checkout of this repository instead of downloading.
    Skips the network. Mainly for CI and offline use.

.PARAMETER ContentRef
    Repository branch/ref to download and use. Defaults to this release branch
    (v3). Studio passes its resolved toolkit branch here.

.PARAMETER Conventions
    skills / agents-md: where the skills and guidelines go, comma-separated:
    "agents" (.agents/skills, AGENTS.md -- Codex, OpenCode, Junie and other
    agents of these conventions) and/or "claude" (.claude/skills, CLAUDE.md --
    Claude Code). Agent names work too (-Agents of earlier releases): codex,
    opencode and junie mean agents.

.PARAMETER Agents
    MCP subcommands: comma-separated agents (e.g. "claude,codex"): claude,
    codex, opencode, junie. claude also sets up Claude Desktop when it is
    installed here.

.PARAMETER Servers
    mcp: comma-separated MCP servers: jetbrains, context7, playwright.

.PARAMETER Scope
    skills: "global" (default) links the skills into the user home, "local"
    into the current project: they are kept in its .agents/skills (also when
    only "claude" is chosen) and linked into .claude/skills. An old .skills
    store of the project is migrated and removed.
    MCP subcommands: "local" (default) writes the project files in the current
    directory (.mcp.json, .codex\config.toml, opencode.json,
    .junie\mcp\mcp.json); "global" writes each agent's user config. Claude
    Desktop has only a user config.

.PARAMETER Context7Key
    Context7 API key (mcp, mcp-context7). Prompted interactively when missing;
    "skip" leaves Context7 out. At local scope the key is written into the
    project files: keep them out of version control. Letters, digits, '.', '_'
    and '-' only.

.PARAMETER BackupExistingFiles
    When set, an existing destination file or folder is renamed to a deduped
    <name>.bak (then .bak1, .bak2, ... if that name is taken) instead of being
    deleted before the new content is copied. Off by default. Local skill
    folders that get replaced are moved to the project's .agents/.jmix/backups/
    (deduped the same way) instead, so no agent reads them as skills. Project
    guidelines are merged rather than overwritten and are not covered by this
    switch: a backup is made only when the toolkit rewrites content it does
    not own -- replacing a guidelines file an older toolkit version installed,
    or adding the block to your own file. Replacing only the marked region
    never makes a backup, and a file that is already up to date is left
    untouched.

.NOTES
    Environment: JMIX_IDE_MCP_PORT sets the port of the IntelliJ IDEA MCP
    server (default 64342).

.EXAMPLE
    Invoke-RestMethod https://raw.githubusercontent.com/jmix-framework/jmix-agent-toolkit/HEAD/install.ps1 | Invoke-Expression

.EXAMPLE
    & ([scriptblock]::Create((iwr -useb https://raw.githubusercontent.com/jmix-framework/jmix-agent-toolkit/HEAD/install.ps1).Content)) skills -Conventions claude
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Subcommand = '',
    [string]$Source = '',
    [string]$Agents = '',
    [string]$Conventions = '',
    [string]$Servers = '',
    [string]$Scope = '',
    [string]$Context7Key = '',
    [string]$ContentRef = 'v3',
    [switch]$BackupExistingFiles
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Branch identity defaults to this release branch. Studio overrides it when a
# feature branch is pinned in the Registry.

$script:RepoOwner = 'jmix-framework'
$script:RepoName  = 'jmix-agent-toolkit'

$script:AllAgents = @('claude', 'codex', 'opencode', 'junie')
# Where skills and guidelines go: 'agents' -- .agents/skills and AGENTS.md
# (Codex, OpenCode, Junie and other agents of those open conventions) -- and
# 'claude' -- .claude/skills and CLAUDE.md (Claude Code).
$script:AllConventions = @('agents', 'claude')
$script:AllMcpServers = @('jetbrains', 'context7', 'playwright')

# IntelliJ IDEA's MCP server listens on 127.0.0.1 only. Its default port is
# 64342; another JetBrains IDE started first moves it, hence the override.
$script:JbPort = if ($env:JMIX_IDE_MCP_PORT) { $env:JMIX_IDE_MCP_PORT } else { '64342' }
# 'stream' (IntelliJ 2026.1+) or 'sse' (2025.2/2025.3); see Resolve-JetbrainsTransport.
$script:JbTransport = 'stream'
# True when the IDE did not answer and JbTransport is only assumed.
$script:JbGuessed = $false
$script:Context7Url = 'https://mcp.context7.com/mcp'
$script:PlaywrightMcpPkg = '@playwright/mcp@latest'
# Set by any MCP agent step that fails; the MCP subcommands then exit 1.
$script:McpFailed = $false
# True while writing entries that carry the Context7 key; see Save-McpConfig.
$script:McpPrivate = $false
# Project files the Context7 key went into during this step (local scope).
$script:McpKeyFiles = @()
# Set when Save-McpConfig created or updated its file.
$script:ConfigChanged = $false

$script:TarballReady     = $false
$script:Staging          = $null
$script:ExtractedDir     = $null
$script:SourceSkillsDir  = $null
$script:SourceGuidelinesBlock = $null
$script:ResolvedVersionDir = $null
# Where replaced skill folders are backed up: the project's .agents/.jmix/backups
# at local scope, out of the dirs the agents read skills from. Empty: beside
# the original, as every other backup.
$script:SkillBackupDir   = ''
$script:IsWindowsHost    = ($env:OS -eq 'Windows_NT')
# The profile folder the agents keep their user configs in. Windows PowerShell
# 5.1's $HOME is HOMEDRIVE+HOMEPATH, a mapped drive on some domain machines.
# USERPROFILE (what Node-based agents read) comes first, so it can be redirected.
$script:UserHome = if ($script:IsWindowsHost -and $env:USERPROFILE) { $env:USERPROFILE }
                   else { [Environment]::GetFolderPath('UserProfile') }
if (-not $script:UserHome) { $script:UserHome = $HOME }

# =================================================================
# Helpers
# =================================================================

function Write-Info {
    param([string]$Message)
    Write-Output $Message
}

# Emits a machine-readable change marker consumed by Jmix Studio's finish step.
# Gated by JMIX_EMIT_CHANGE_MARKERS so manual CLI runs print nothing extra.
function Write-ChangeMarker {
    param([string]$Action, [string]$Type, [string]$Path)
    if ($env:JMIX_EMIT_CHANGE_MARKERS -ne '1') { return }
    Write-Output "@@JMIX_CHANGE@@`taction=$Action`ttype=$Type`tpath=$Path"
}

# Emits environment + tool versions through Write-Verbose (shown only with -Verbose)
# to help diagnose user problems.
function Write-EnvDiagnostics {
    Write-Verbose "os: $([System.Environment]::OSVersion.VersionString)"
    Write-Verbose "pwd: $((Get-Location).Path)"
    Write-Verbose "HOME: $HOME, user profile: $($script:UserHome)"
    Write-Verbose "profile: $($script:UserHome)"
    Write-Verbose "PSVersion: $($PSVersionTable.PSVersion)"
    foreach ($tool in 'git', 'node', 'npx') {
        $cmd = Get-Command $tool -ErrorAction SilentlyContinue
        Write-Verbose "${tool}: $(if ($cmd) { $cmd.Source } else { 'not found' })"
    }
}

function Write-Err {
    param([string]$Message)
    [Console]::Error.WriteLine("error: $Message")
}

function Write-ErrAndExit {
    param([string]$Message)
    Write-Err $Message
    exit 1
}

# MCP servers started through npx need Node.js on the machine the agent runs
# on, not at install time, so a missing npx is only a note.
function Write-NpxNote {
    param([string]$What)
    if (Get-Command npx -ErrorAction SilentlyContinue) { return }
    Write-Info ''
    Write-Info "Note: $What starts through npx, which is not on PATH here. Install Node.js 20+ (https://nodejs.org) before using it."
}

function Read-Prompt {
    param(
        [string]$Message,
        [string]$Default = ''
    )
    $hint = ''
    if ($Default) { $hint = " [$Default]" }
    $answer = Read-Host "$Message$hint"
    if ([string]::IsNullOrEmpty($answer) -and $Default) {
        return $Default
    }
    return $answer
}

function Read-YesNo {
    param(
        [string]$Message,
        [string]$Default = 'y'
    )
    $hint = if ($Default -eq 'n') { '[y/N]' } else { '[Y/n]' }
    $answer = Read-Prompt -Message "$Message $hint" -Default $Default
    return ($answer -match '^(y|yes)$')
}

function Get-AgentLabel {
    param([string]$Agent)
    switch ($Agent) {
        'claude'   { 'Claude CLI' }
        'codex'    { 'Codex' }
        'opencode' { 'OpenCode' }
        'junie'    { 'Junie' }
        default    { $Agent }
    }
}

function Get-SkillsLabel {
    param([string]$Convention)
    switch ($Convention) {
        'agents' { '.agents/skills (Codex, OpenCode, Junie, ...)' }
        'claude' { '.claude/skills (Claude Code)' }
    }
}

function Get-GuidelinesLabel {
    param([string]$Convention)
    switch ($Convention) {
        'agents' { 'AGENTS.md (Codex, OpenCode, Junie, ...)' }
        'claude' { 'CLAUDE.md (Claude Code)' }
    }
}

function Get-ServerLabel {
    param([string]$Server)
    switch ($Server) {
        'jetbrains'  { 'JetBrains (code insight from IntelliJ IDEA)' }
        'context7'   { 'Context7 (library docs, needs an API key)' }
        'playwright' { 'Playwright (browser automation)' }
    }
}

# Returns a not-yet-existing backup file NAME (bare, no directory) for the item
# at $Path: first "<name>.bak", then on collision "<name>.bak1", ".bak2", ... so
# an earlier backup is never overwritten. The name is free in folder $Dir,
# by default the item's own.
function Get-DedupBackupName {
    param([string]$Path, [string]$Dir = '')
    if (-not $Dir) { $Dir = Split-Path -Parent $Path }
    $name = [System.IO.Path]::GetFileName($Path)
    $candidate = "$name.bak"
    $n = 1
    while (Test-Path -LiteralPath (Join-Path $Dir $candidate)) {
        $candidate = "$name.bak$n"
        $n++
    }
    return $candidate
}

# Moves skill folder $Path to a deduped <name>.bak in $script:SkillBackupDir
# (created on first use), or beside $Path when that is empty. Returns the
# backup's path.
function Backup-SkillDir {
    param([string]$Path)
    $dir = $script:SkillBackupDir
    if (-not $dir) { $dir = Split-Path -Parent $Path }
    elseif (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $backup = Join-Path $dir (Get-DedupBackupName -Path $Path -Dir $dir)
    Move-Item -LiteralPath $Path -Destination $backup -ErrorAction Stop
    return $backup
}

# Copies skill folder $Src to $Dest. A folder already there is backed up
# (-BackupExistingFiles) or removed. A link there is never followed: only the
# link itself goes. When backups go to $script:SkillBackupDir (local scope,
# where an older layout linked the store's skills) a link is only removed:
# moved there, a relative one would dangle; at global scope it is backed up
# beside itself, as every global backup.
function Write-Dest {
    param(
        [string]$Src,
        [string]$Dest,
        [string]$Label
    )
    # Get-Item -Force also finds a dangling link, which Test-Path may not.
    $existing = Get-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
    $backupInfo = ''
    if ($existing -and $existing.LinkType -and ($script:SkillBackupDir -or -not $BackupExistingFiles)) {
        Remove-Link -Item $existing
    } elseif ($existing) {
        if ($BackupExistingFiles) {
            $backupInfo = " (backup: $(Split-Path -Leaf (Backup-SkillDir -Path $Dest)))"
        } else {
            Remove-Item -LiteralPath $Dest -Recurse -Force -ErrorAction Stop
        }
    }
    Copy-Item -Path $Src -Destination $Dest -Recurse -Force -ErrorAction Stop
    if ($existing) {
        Write-Info "  Updated: $Label$backupInfo"
    } else {
        Write-Info "  Installed: $Label"
    }
}

# Parses comma-separated list $Csv, given in option $Option of $Subcommand.
# Every value must be one of $Valid; returns them in $Valid's order, each once.
function Resolve-Csv {
    param([string]$Csv, [string]$Subcommand, [string]$Option, [string[]]$Valid)
    $tokens = @($Csv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($tokens.Count -eq 0) {
        Write-ErrAndExit "${Subcommand}: $Option is required (one or more of: $($Valid -join ','))"
    }
    foreach ($t in $tokens) {
        if ($Valid -notcontains $t) {
            Write-ErrAndExit "${Subcommand}: unknown value '$t' in $Option (valid: $($Valid -join ','))"
        }
    }
    return @($Valid | Where-Object { $tokens -contains $_ })
}

function Resolve-AgentsCsv {
    param([string]$Csv, [string]$Subcommand)
    return Resolve-Csv -Csv $Csv -Subcommand $Subcommand -Option '-Agents' -Valid $script:AllAgents
}

# -Conventions of skills / agents-md. Agent names (the -Agents of earlier
# releases) are accepted too: codex, opencode and junie follow the agents
# convention.
function Resolve-ConventionsCsv {
    param([string]$Csv, [string]$Subcommand)
    $mapped = @($Csv -split ',' | ForEach-Object {
        $t = $_.Trim()
        if ($t -in 'codex', 'opencode', 'junie') { 'agents' } else { $t }
    }) -join ','
    return Resolve-Csv -Csv $mapped -Subcommand $Subcommand -Option '-Conventions' -Valid $script:AllConventions
}

# =================================================================
# Tarball + version resolution
# =================================================================

function Initialize-Tarball {
    if ($script:TarballReady) { return }

    if ($Source) {
        # Install from a local checkout instead of downloading. Skips the network
        # entirely and overrides -Ref. Used by CI and offline installs.
        if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
            Write-ErrAndExit "source directory not found: $Source"
        }
        $script:ExtractedDir = (Resolve-Path -LiteralPath $Source).Path
        Write-Verbose "using local source dir: $($script:ExtractedDir) (download skipped)"
    } else {
        if (-not (Get-Command Expand-Archive -ErrorAction SilentlyContinue)) {
            Write-ErrAndExit 'Expand-Archive not found. PowerShell 5+ is required.'
        }

        $script:Staging = Join-Path ([System.IO.Path]::GetTempPath()) ("jmix-install-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Staging -Force | Out-Null

        $zipPath = Join-Path $script:Staging 'source.zip'
        Write-Verbose "staging: $($script:Staging)"

        $archiveUrl = "https://codeload.github.com/$($script:RepoOwner)/$($script:RepoName)/zip/$ContentRef"
        Write-Verbose "archiveUrl: $archiveUrl"
        Write-Info "Downloading $archiveUrl"
        $downloaded = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Invoke-WebRequest -UseBasicParsing -Uri $archiveUrl -OutFile $zipPath -TimeoutSec 300
                $downloaded = $true
                break
            } catch {
                $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                if ($attempt -lt 3) {
                    Write-Info "Download attempt $attempt failed (HTTP $status); retrying in 2s..."
                    Start-Sleep -Seconds 2
                }
            }
        }
        if (-not $downloaded) { Write-ErrAndExit "failed to download $archiveUrl" }

        Expand-Archive -Path $zipPath -DestinationPath $script:Staging -Force

        $script:ExtractedDir = (Get-ChildItem -Path $script:Staging -Directory |
            Where-Object { $_.Name -like "$($script:RepoName)-*" } |
            Select-Object -First 1).FullName

        if (-not $script:ExtractedDir) {
            Write-ErrAndExit "extracted source directory not found in $($script:Staging)"
        }
    }

    $contentDir = Join-Path $script:ExtractedDir 'content'
    $script:SourceSkillsDir = Join-Path $contentDir 'skills'
    if (-not (Test-Path $script:SourceSkillsDir -PathType Container)) {
        Write-ErrAndExit "content/skills not found in $(if ($Source) { $Source } else { $ContentRef })"
    }
    $script:SourceGuidelinesBlock = Join-Path $contentDir 'guidelines-block.md'

    # Store segment under ~/.agents/.jmix/skills/<seg>: the branch name, so multiple
    # Jmix majors coexist on one machine.
    $script:ResolvedVersionDir = $ContentRef

    Write-Verbose "extracted dir: $($script:ExtractedDir)"
    Write-Verbose "store segment: $($script:ResolvedVersionDir)"
    Write-Verbose "source skills dir: $($script:SourceSkillsDir)"
    Write-Info "Using guidelines from $($script:SourceSkillsDir.Substring($script:ExtractedDir.Length + 1))"

    $script:TarballReady = $true
}

# =================================================================
# skills install (global, per agent)
# =================================================================

# Validates -Scope. $Default applies when it is empty: 'global' for skills,
# 'local' for the MCP subcommands.
function Resolve-Scope {
    param([string]$Scope, [string]$Default = 'global', [string]$Subcommand = 'skills')
    if ([string]::IsNullOrWhiteSpace($Scope)) { return $Default }
    switch ($Scope) {
        'global' { return 'global' }
        'local'  { return 'local' }
        default  { Write-ErrAndExit "${Subcommand}: -Scope must be 'global' or 'local' (got '$Scope')" }
    }
}

# Relative skills dir of convention $Convention.
function Get-ConventionSkillsDir {
    param([string]$Convention)
    switch ($Convention) {
        'agents' { '.agents/skills' }
        'claude' { '.claude/skills' }
        default  { throw "unknown convention '$Convention'" }
    }
}

# Earlier versions also linked the skills into .junie/skills. Junie reads
# .agents/skills now, and its CLI reads ~/.junie/skills first, so links left
# there would shadow newer skills: the toolkit's own links are removed. Only
# when .agents/skills holds the skills -- this run linked it, or it is the local
# store (otherwise Junie would be left with no skills) -- and never from a
# .junie/skills that is the same folder as an agent skills dir: its links are
# the ones this run just created.
function Remove-OldJunieSkillLinks {
    param([string]$Root, [string[]]$Conventions, [string]$Scope)
    $dir = Join-Path $Root '.junie/skills'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
    if ($Scope -ne 'local' -and $Conventions -notcontains 'agents') { return }
    foreach ($rel in '.agents/skills', '.claude/skills') {
        if (Test-SameDirectory -Path (Join-Path $Root $rel) -Other $dir) { return }
    }
    foreach ($item in Get-ChildItem -LiteralPath $dir -Force) {
        if (-not $item.LinkType -or $item.Name -notmatch '^jmix(-|$)') { continue }
        # Only links into a toolkit store: ~/.agents/.jmix/skills/... or the old <project>/.skills/...
        $target = [string](@($item.Target) | Select-Object -First 1)
        if ($target -notmatch '(?:^|[\\/])(?:\.agents[\\/]\.jmix[\\/]skills|\.skills)[\\/].') { continue }
        Remove-Link -Item $item
        Write-Info "  Removed old Junie skill link $($item.FullName)"
    }
    if (-not (Get-ChildItem -LiteralPath $dir -Force)) { [System.IO.Directory]::Delete($dir, $false) }
}

# Prints remediation guidance for enabling symbolic-link creation.
function Write-SymlinkGuidance {
    Write-Info 'Installing skills requires symbolic-link support, which is not available in this session.'
    Write-Info 'On Windows, enable one of the following and re-run:'
    Write-Info '  - Developer Mode: Settings -> Privacy & security -> For developers -> Developer Mode (On), or'
    Write-Info '  - run this terminal as Administrator.'
}

# Creates/refreshes a whole-dir link $Link -> $Target. Replaces an existing link,
# dangling or not; an existing real dir is backed up (when -BackupExistingFiles,
# see Backup-SkillDir) or removed.
# Link strategy, best-effort in order:
#   1. Directory junction (Windows only) -- needs no Developer Mode / admin and
#      covers every link here (store and agent dir share the local user home).
#      New-Item silently no-ops for Junction on non-Windows, so it is gated on the
#      host and the attempt is confirmed with Test-Path.
#   2. Symbolic link -- always works on Unix; on Windows needs Developer Mode/admin
#      and also handles cross-volume/UNC targets a junction can't.
# When neither succeeds the install is aborted with guidance (it is never silently
# degraded to a plain copy). A `throw` (not `exit`) lets the interactive wizard's
# per-step catch skip gracefully while the non-interactive subcommand exits non-zero.
function New-DirSymlink {
    param([string]$Link, [string]$Target)
    # Get-Item -Force also finds a dangling link, which Test-Path may not.
    $item = Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType) {
        # Delete the reparse point itself, never the target. `Remove-Item -Force`
        # without -Recurse prompts on Windows PowerShell 5.1 (the junction looks
        # non-empty), which hangs a non-interactive (Studio) re-run; -Recurse would
        # instead delete the target's contents. Remove-Link does neither -- it
        # unlinks the junction/symlink without prompting.
        Remove-Link -Item $item
    } elseif ($item) {
        if ($BackupExistingFiles) { $null = Backup-SkillDir -Path $Link }
        else { Remove-Item -LiteralPath $Link -Recurse -Force }
    }
    $parent = Split-Path -Parent $Link
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    if ($script:IsWindowsHost) {
        try {
            New-Item -ItemType Junction -Path $Link -Target $Target -ErrorAction Stop | Out-Null
            if (Test-Path $Link) { return }
        } catch { }
    }
    try {
        New-Item -ItemType SymbolicLink -Path $Link -Target $Target -ErrorAction Stop | Out-Null
        if (Test-Path $Link) { return }
    } catch { }
    Write-SymlinkGuidance
    throw 'symbolic links are not available (enable Windows Developer Mode or run as Administrator)'
}

function Install-SkillsToStore {
    param([string]$StoreDir)
    Write-Info ''
    Write-Info "Installing skills into store $StoreDir"
    # Clear a broken-symlink store or store base (e.g. .agents -> missing) so creation works.
    Clear-DanglingSymlink -Path (Split-Path -Parent $StoreDir)
    Clear-DanglingSymlink -Path $StoreDir
    if (-not (Test-Path $StoreDir)) { New-Item -ItemType Directory -Path $StoreDir -Force | Out-Null }
    foreach ($skill in Get-ChildItem -Path $script:SourceSkillsDir -Directory) {
        $dest = Join-Path $StoreDir $skill.Name
        Write-Dest -Src $skill.FullName -Dest $dest -Label $skill.Name
    }
}

# Removes a path only when it is a dangling (broken) symlink, so directory creation
# does not fail when an agent base/dir (e.g. ~/.junie) points at a missing target.
# A symlink that resolves to an existing directory is left untouched.
function Clear-DanglingSymlink {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or -not $item.LinkType) { return }
    $target = @($item.Target) | Select-Object -First 1
    if ($target -and (Test-Path -LiteralPath (Resolve-LinkTarget -Link $item.FullName -Target $target))) { return }
    if ($BackupExistingFiles) {
        Rename-Item -LiteralPath $Path -NewName (Get-DedupBackupName -Path $Path) -ErrorAction SilentlyContinue
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item) { Remove-Link -Item $item }
}

# The full path link $Link's target $Target names: a relative target is
# relative to the link's own folder; an absolute one is kept as is.
function Resolve-LinkTarget {
    param([string]$Link, [string]$Target)
    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Split-Path -Parent $Link), $Target))
}

# Deletes link $Item itself, never what it points to: Remove-Item -Recurse
# could reach through it.
function Remove-Link {
    param([System.IO.FileSystemInfo]$Item)
    if ($Item.PSIsContainer) { [System.IO.Directory]::Delete($Item.FullName, $false) }
    else { [System.IO.File]::Delete($Item.FullName) }
}

# True when folders $Path and $Other are the same folder, through any symlink
# or junction: a marker file created in $Path shows up in $Other. Windows
# PowerShell 5.1 cannot resolve link targets, so this works on every version.
# ponytail: writes a marker; fails safe (false) where $Path is not writable.
function Test-SameDirectory {
    param([string]$Path, [string]$Other)
    if (-not (Test-Path -LiteralPath $Path -PathType Container) -or
        -not (Test-Path -LiteralPath $Other -PathType Container)) { return $false }
    $name = '.jmix-same-dir.' + [guid]::NewGuid().ToString('N')
    $marker = Join-Path $Path $name
    try { [System.IO.File]::WriteAllBytes($marker, [byte[]]@()) } catch { return $false }
    try { return (Test-Path -LiteralPath (Join-Path $Other $name)) }
    finally { Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue }
}

# Per-skill symlinks: link each store skill folder into the agent skills dir,
# so Jmix skills coexist with other skills already present there. Only the
# skills being installed are linked: at global scope the store also keeps the
# backups that -BackupExistingFiles makes there. An agent dir that is the store
# itself (.agents/skills at local scope, or e.g. .claude/skills ->
# ../.agents/skills) already holds the skills; links there would point at
# themselves.
function New-SkillSymlinks {
    param([string]$AgentDir, [string]$StoreDir)
    $existed = Test-Path $AgentDir
    # Clear a broken-symlink agent base/dir (e.g. ~/.junie -> missing) so creation works.
    Clear-DanglingSymlink -Path (Split-Path -Parent $AgentDir)
    Clear-DanglingSymlink -Path $AgentDir
    if (-not (Test-Path $AgentDir)) { New-Item -ItemType Directory -Path $AgentDir -Force | Out-Null }
    if (Test-SameDirectory -Path $AgentDir -Other $StoreDir) {
        Write-Info "  $AgentDir is the skills store itself; nothing to link"
        return
    }
    foreach ($skill in Get-ChildItem -Path $script:SourceSkillsDir -Directory) {
        $link = Join-Path $AgentDir $skill.Name
        New-DirSymlink -Link $link -Target (Join-Path $StoreDir $skill.Name)
    }
    # Earlier versions linked those store backups too; their links go.
    foreach ($item in Get-ChildItem -LiteralPath $AgentDir -Force -Filter '*.bak*') {
        if (-not $item.LinkType) { continue }
        $target = Resolve-LinkTarget -Link $item.FullName -Target ([string](@($item.Target) | Select-Object -First 1))
        if ((Split-Path -Leaf $target) -eq $item.Name -and
            (Test-SameDirectory -Path (Split-Path -Parent $target) -Other $StoreDir)) { Remove-Link -Item $item }
    }
    Write-ChangeMarker -Action $(if ($existed) { 'updated' } else { 'created' }) -Type 'dir' -Path $AgentDir
    Write-Info "  Linked skills into $AgentDir"
}

# The -Conventions of skills / agents-md, or the -Agents of earlier releases.
function Get-ConventionsArg {
    if ($Conventions) { return $Conventions }
    return $Agents
}

# The skills store of scope $Scope under $Root (the project or the user home).
# Local skills are kept in the project's .agents/skills -- also when only
# "claude" is chosen -- and linked into .claude/skills; global ones in
# ~/.agents/.jmix/skills/<branch>, so multiple Jmix majors coexist.
function Get-SkillsStoreDir {
    param([string]$Scope, [string]$Root)
    if ($Scope -eq 'local') { return Join-Path $Root '.agents/skills' }
    return Join-Path $Root (Join-Path '.agents/.jmix/skills' $script:ResolvedVersionDir)
}

# Earlier versions kept the local skills in <project>/.skills and linked them
# into .agents/skills and .claude/skills. Runs once the new store is filled and
# linked, so a failure before it leaves the old layout working: every
# <project>/.*/skills dir (other agents' too) is swept of the old store (see
# Update-LegacySkillLinks), then .skills is emptied of its Jmix entries (see
# Remove-LegacySkillEntries). A .skills that is a link is the user's own setup:
# left alone. One that is an agent skills dir (e.g. .claude/skills -> ../.skills)
# is live: kept, and linked like .claude/skills so it does not go stale. Names
# match case-sensitively, as in install.sh.
function Remove-LegacySkillsStore {
    param([string]$Root, [string]$StoreDir)
    $legacy = Join-Path $Root '.skills'
    $legacyItem = Get-Item -LiteralPath $legacy -Force -ErrorAction SilentlyContinue
    if ($legacyItem -and $legacyItem.LinkType) { return }
    $skillNames = @(Get-ChildItem -Path $script:SourceSkillsDir -Directory | ForEach-Object { $_.Name })
    # ponytail: agent dirs are <root>/.*/skills; add others if an agent reads elsewhere.
    $agentDirs = @(Get-ChildItem -LiteralPath $Root -Directory -Force | Where-Object { $_.Name.StartsWith('.') } |
        ForEach-Object { Join-Path $_.FullName 'skills' } | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    foreach ($dir in $agentDirs) {
        if (-not (Test-SameDirectory -Path $legacy -Other $dir)) { continue }
        if (-not (Test-SameDirectory -Path $dir -Other $StoreDir)) {
            foreach ($name in $skillNames) { New-DirSymlink -Link (Join-Path $dir $name) -Target (Join-Path $StoreDir $name) }
        }
        Write-Info "  Kept the old skills store ${legacy}: $dir links to it"
        return
    }
    foreach ($dir in $agentDirs) { Update-LegacySkillLinks -Dir $dir -Root $Root -StoreDir $StoreDir -SkillNames $skillNames }
    if ($legacyItem -and $legacyItem.PSIsContainer) { Remove-LegacySkillEntries -Legacy $legacy -SkillNames $skillNames }
}

# In agent skills dir $Dir, links named jmix* into the old <project>/.skills are
# re-linked to the store (a skill being installed) or removed (retired skills,
# old backups), and real jmix*.bak* folders older versions left beside the
# skills move to the backups dir, where agents do not read them.
function Update-LegacySkillLinks {
    param([string]$Dir, [string]$Root, [string]$StoreDir, [string[]]$SkillNames)
    $legacyFull = [System.IO.Path]::GetFullPath((Join-Path $Root '.skills'))
    # A relative link target counts from the dir's real folder.
    # ponytail: follows one level of link, enough for a linked agent dir.
    $dirItem = Get-Item -LiteralPath $Dir -Force
    $realDir = $Dir
    if ($dirItem.LinkType) { $realDir = Resolve-LinkTarget -Link $Dir -Target ([string](@($dirItem.Target) | Select-Object -First 1)) }
    $moved = 0
    foreach ($item in Get-ChildItem -LiteralPath $Dir -Force) {
        if ($item.Name -cnotmatch '^jmix($|[-.])') { continue }
        if (-not $item.LinkType) {
            if ($item.PSIsContainer -and $item.Name -clike '*.bak*') { $null = Backup-SkillDir -Path $item.FullName; $moved++ }
            continue
        }
        $target = Resolve-LinkTarget -Link (Join-Path $realDir $item.Name) -Target ([string](@($item.Target) | Select-Object -First 1))
        $parent = Split-Path -Parent $target
        # .skills under another spelling of the project path (e.g. macOS
        # /var -> /private/var) counts too.
        # ponytail: one marker write per link; cache by folder if it shows.
        if ($parent -ne $legacyFull -and -not ((Split-Path -Leaf $parent) -eq '.skills' -and
                (Test-SameDirectory -Path $Root -Other (Split-Path -Parent $parent)))) { continue }
        # In the store a skill being installed is a real folder by now, so
        # such a link is in another agent's dir.
        if ($SkillNames -ccontains $item.Name) {
            New-DirSymlink -Link $item.FullName -Target (Join-Path $StoreDir $item.Name)
        } else {
            Remove-Link -Item $item
        }
        $moved++
    }
    if ($moved) { Write-Info "  Re-linked, removed or backed up $moved entries of the old skills store in $Dir" }
}

# Removes the Jmix entries of the old store $Legacy: the toolkit's skills and
# their old backups are deleted (backed up with -BackupExistingFiles), any other
# jmix* entry, retired or the user's own, is always backed up. $Legacy goes when
# nothing else is left in it.
function Remove-LegacySkillEntries {
    param([string]$Legacy, [string[]]$SkillNames)
    foreach ($item in Get-ChildItem -LiteralPath $Legacy -Force) {
        if ($item.Name -cnotmatch '^jmix($|[-.])') { continue }
        $isToolkit = $SkillNames -ccontains ($item.Name -creplace '\.bak.*$', '')
        if ($item.LinkType) { Remove-Link -Item $item }
        elseif ($BackupExistingFiles -or -not $isToolkit) {
            $backup = Backup-SkillDir -Path $item.FullName
            Write-Info "  Backed up $($item.FullName) to $backup"
        }
        else { Remove-Item -LiteralPath $item.FullName -Recurse -Force }
    }
    # Clutter Finder and Explorer leave is not the user's.
    foreach ($n in '.DS_Store', 'Thumbs.db', 'desktop.ini') {
        Remove-Item -LiteralPath (Join-Path $Legacy $n) -Force -ErrorAction SilentlyContinue
    }
    if (@(Get-ChildItem -LiteralPath $Legacy -Force).Count -eq 0) {
        [System.IO.Directory]::Delete($Legacy, $false)
        Write-Info "  Removed the old skills store $Legacy"
    } else {
        Write-Info "  Kept the old skills store ${Legacy}: it holds other files"
    }
}

# Installs the skills for conventions $ConventionList at scope $Scope: fills the
# store, links it into each convention's skills dir and tidies up after earlier
# versions. Shared by the skills subcommand and the wizard.
function Install-Skills {
    param([string[]]$ConventionList, [string]$Scope)
    $root = if ($Scope -eq 'local') { (Get-Location).Path } else { $script:UserHome }
    $storeDir = Get-SkillsStoreDir -Scope $Scope -Root $root
    $script:SkillBackupDir = if ($Scope -eq 'local') { Join-Path $root '.agents/.jmix/backups' } else { '' }

    $storeExisted = Test-Path $storeDir
    Write-Verbose "scope=$Scope root=$root store=$storeDir"
    Install-SkillsToStore -StoreDir $storeDir
    Write-ChangeMarker -Action $(if ($storeExisted) { 'updated' } else { 'created' }) -Type 'dir' -Path $storeDir

    Write-Info ''
    Write-Info 'Linking store skills into agent dirs'
    foreach ($c in $ConventionList) {
        New-SkillSymlinks -AgentDir (Join-Path $root (Get-ConventionSkillsDir -Convention $c)) -StoreDir $storeDir
    }
    Remove-OldJunieSkillLinks -Root $root -Conventions $ConventionList -Scope $Scope
    if ($Scope -eq 'local') { Remove-LegacySkillsStore -Root $root -StoreDir $storeDir }

    Write-Info ''
    Write-Info "Done. Installed $Scope skills store at $storeDir and linked: $($ConventionList -join ', ')"
}

function Invoke-CmdSkills {
    $conventionList = Resolve-ConventionsCsv -Csv (Get-ConventionsArg) -Subcommand 'skills'
    $resolvedScope = Resolve-Scope -Scope $Scope
    Initialize-Tarball
    Install-Skills -ConventionList $conventionList -Scope $resolvedScope
}

# =================================================================
# agents-md install (project-level)
# =================================================================

# Project guidelines file of convention $Convention.
function Get-ConventionGuidelinesFile {
    param([string]$Convention)
    $proj = (Get-Location).Path
    switch ($Convention) {
        'agents' { Join-Path $proj 'AGENTS.md' }
        'claude' { Join-Path $proj 'CLAUDE.md' }
        default  { throw "unknown convention '$Convention'" }
    }
}

# Codex reads AGENTS.override.md instead of AGENTS.md in the same dir, and only
# the first 32 KiB (project_doc_max_bytes) of its project docs. Notes when
# either keeps the block in AGENTS.md $AgentsMd from Codex.
function Write-CodexBlockNotes {
    param([string]$AgentsMd)
    $dir = Split-Path -Parent $AgentsMd
    if (Test-Path -LiteralPath (Join-Path $dir 'AGENTS.override.md')) {
        Write-Info "  Note: Codex reads $(Join-Path $dir 'AGENTS.override.md') instead of AGENTS.md there, so it does not see the Jmix block. Copy the block into it."
    }
    # Byte-preserving text: a char index is a byte offset.
    $end = (Get-FileTextRaw -Path $AgentsMd).LastIndexOf($script:BlockEnd, [System.StringComparison]::Ordinal)
    if ($end -ge 0 -and $end + $script:BlockEnd.Length -gt 32768) {
        Write-Info '  Note: Codex reads only the first 32 KiB of AGENTS.md, and the Jmix block ends past that. Move the block (with its markers) to the top.'
    }
}

# The marker pair delimiting the toolkit-managed region inside a project
# guidelines file. Must match content/guidelines-block.md and install.sh exactly.
$script:BlockBegin = '<!-- BEGIN jmix-agent-toolkit -->'
$script:BlockEnd   = '<!-- END jmix-agent-toolkit -->'

# Treat strings in this section as byte containers. ISO-8859-1 maps every byte
# to one code point and back, so marker splicing never decodes or re-encodes the
# developer's file. The UTF-8 bytes of guidelines-block.md also pass unchanged.
$script:BytePreservingEncoding = [System.Text.Encoding]::GetEncoding(28591)
# A UTF-8 BOM as Get-FileTextRaw represents it.
$script:RawBom = [char]0x00EF + [char]0x00BB + [char]0x00BF

# Reads bytes, not text: File.ReadAllText would honour a BOM, drop it and
# decode the rest as UTF-8, which Set-FileTextRaw could not write back.
function Get-FileTextRaw {
    param([string]$Path)
    return $script:BytePreservingEncoding.GetString([System.IO.File]::ReadAllBytes($Path))
}

# Writes the exact bytes represented by Get-FileTextRaw.
function Set-FileTextRaw {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, $script:BytePreservingEncoding)
}

# Writes $Text to a temp file in $Dest's directory, then moves it over $Dest.
# Staging into a temp file first (instead of writing $Dest directly) means a
# write that fails partway never truncates the developer's own text above and
# below the marker region; the temp file is removed on any failure path so a
# failed run never leaves a stray temp file in the developer's project.
# A symlinked $Dest (e.g. CLAUDE.md -> AGENTS.md) is written through instead, so
# the link itself survives -- Move-Item would replace it with a plain file.
# On Unix an existing $Dest keeps its permission bits, and a new one is 0600
# with -Private (it may hold an API key); Windows keeps the folder's ACL.
function Set-FileTextAtomic {
    param([string]$Dest, [string]$Text, [string]$TempPrefix = '.jmix-guidelines.', [switch]$Private)
    $destItem = Get-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
    if ($destItem -and $destItem.LinkType) {
        if ($script:McpPrivate) { Protect-OwnerOnly -Path $Dest }
        Set-FileTextRaw -Path $Dest -Text $Text
        return
    }
    $destDir = Split-Path -Parent $Dest
    $tmp = Join-Path $destDir ($TempPrefix + [guid]::NewGuid().ToString('N'))
    try {
        # The temp file gets its final mode while still empty: the text may
        # hold an API key.
        [System.IO.File]::WriteAllBytes($tmp, [byte[]]@())
        $modeFrom = if ($destItem) { $Dest } else { '' }
        Copy-UnixFileMode -From $modeFrom -To $tmp -Private:$Private
        Set-FileTextRaw -Path $tmp -Text $Text
        Move-Item -LiteralPath $tmp -Destination $Dest -Force -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

# Unix file modes need .NET 7+ (pwsh 7.3+); elsewhere files keep the default
# mode, and Windows keeps the folder's ACL.
function Test-UnixFileModeApi {
    return (-not $script:IsWindowsHost -and
            $null -ne [System.IO.File].GetMethod('GetUnixFileMode', [type[]]@([string])))
}

# rwx for the owner, nothing for group and others (0700), and rw- (0600).
$script:OwnerBits = 448
$script:OwnerReadWrite = 384

# Gives $To (a temp file, which starts with the umask's mode) the mode of
# $From, or 0600 when there is no $From and -Private is set. While
# $script:McpPrivate is set the result is narrowed to the owner.
function Copy-UnixFileMode {
    param([string]$From, [string]$To, [switch]$Private)
    if (-not (Test-UnixFileModeApi)) { return }
    if ($From) { $mode = [int][System.IO.File]::GetUnixFileMode($From) }
    elseif ($Private) { $mode = $script:OwnerReadWrite }
    else { return }
    if ($script:McpPrivate) { $mode = $mode -band $script:OwnerBits }
    [System.IO.File]::SetUnixFileMode($To, $mode)
}

# chmod go-rwx: leaves $Path (or what it links to) usable by its owner only.
function Protect-OwnerOnly {
    param([string]$Path)
    if (-not (Test-UnixFileModeApi)) { return }
    [System.IO.File]::SetUnixFileMode($Path, [int][System.IO.File]::GetUnixFileMode($Path) -band $script:OwnerBits)
}

# Returns @{ Start; End } for a well-formed toolkit region in $Text, or $null.
# Markers must occupy whole lines and each END is paired with its nearest
# preceding BEGIN. Prefer the last pair carrying the current block heading;
# otherwise use the last pair for compatibility with stale block contents.
# These rules match install.sh and prevent orphan, inline, or indented markers
# from capturing developer content.
function Get-BlockRange {
    param([string]$Text)
    $bom = [char]0x00EF + [char]0x00BB + [char]0x00BF
    $beginPattern = '(?m)^(?:' + [regex]::Escape($bom) + ')?' +
                    [regex]::Escape($script:BlockBegin) + '(?=\r?$)'
    $endPattern = '(?m)^' + [regex]::Escape($script:BlockEnd) + '(?=\r?$)'
    $eventsPattern = $beginPattern + '|' + $endPattern
    $candidate = $null
    $fallback = $null
    $preferred = $null

    foreach ($match in [regex]::Matches($Text, $eventsPattern,
            [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        $normalized = $match.Value.TrimEnd("`r")
        if ($normalized.EndsWith($script:BlockBegin, [System.StringComparison]::Ordinal)) {
            $candidate = $match
            continue
        }
        if ($null -eq $candidate) { continue }

        $contentStart = $candidate.Index + $candidate.Length
        $content = $Text.Substring($contentStart, $match.Index - $contentStart)
        $start = $candidate.Index
        if ($candidate.Value.StartsWith($bom, [System.StringComparison]::Ordinal)) {
            $start += $bom.Length
        }
        $range = @{ Start = $start; End = $match.Index + $match.Length }
        $fallback = $range
        if ($content -cmatch '^\r?\n## Jmix\r?\n') { $preferred = $range }
        $candidate = $null
    }
    if ($null -ne $preferred) { return $preferred }
    return $fallback
}

# Skill names a shipped (pre-block) guidelines file may reference: the toolkit's
# own skills plus the names its earliest files used. A closed set, deliberately
# NOT a bare `jmix-[a-z-]` -- a developer's own file can mention jmix-flowui or
# a github.com/jmix-framework URL without being ours. Must match install.sh.
$script:LegacySkillNamesRe = 'jmix-(add-dialog-detail-flow|add-entity-event-listener|add-i18n-keys|configure-fetch-plan|create-composition-detail-view|create-custom-ui-component|create-detail-view|create-dto-entity|create-entity|create-enum|create-fragment|create-list-view|create-liquibase-changelog|create-resource-role|create-row-level-role|create-service|create-test|fetch-plans|ide-static-analysis|role-based-access|run-background-code|services|style-ui|verify-api-symbol|verify-bootrun)'

# True when $Text looks like a guidelines file this toolkit installed before the
# block existed. Both conditions must hold: the first non-blank line is one of the
# three headings the toolkit has ever shipped, and the body carries one of the
# toolkit's section headings or skill names.
function Test-LegacyGuidelines {
    param([string]$Text)
    $body  = if ($Text.StartsWith($script:RawBom, [System.StringComparison]::Ordinal)) { $Text.Substring($script:RawBom.Length) } else { $Text }
    $first = ($body -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
    if ($first -cne '# Agent Instructions' -and $first -cne '# Coding Guidelines' -and $first -cne '# Jmix Coding Guidelines') { return $false }
    # -cmatch (case-sensitive): install.sh's grep is case-sensitive by default too,
    # so this stays in step with it for mixed-case content.
    return (($Text -match '(?mi)^## Skill routing') -or
            ($Text -cmatch '(?m)^## Skills and MCP') -or
            ($Text -cmatch $script:LegacySkillNamesRe))
}

# True when CLAUDE.md $ClaudeMd already gets the block through the AGENTS.md next
# to it: AGENTS.md carries the block, and CLAUDE.md either is a link to that same
# file or @-imports it -- Claude Code merges `@AGENTS.md` imports at load time.
# Installing the block into CLAUDE.md as well would only duplicate it.
function Test-ClaudeMdCoveredByAgentsMd {
    param([string]$ClaudeMd)
    $dir      = Split-Path -Parent $ClaudeMd
    $agentsMd = Join-Path $dir 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $agentsMd -PathType Leaf)) { return $false }
    if ($null -eq (Get-BlockRange -Text (Get-FileTextRaw -Path $agentsMd))) { return $false }
    $item = Get-Item -LiteralPath $ClaudeMd -Force
    if ($item.LinkType -and $item.Target) {
        $resolved = Resolve-LinkTarget -Link $ClaudeMd -Target @($item.Target)[0]
        if ($resolved -eq [System.IO.Path]::GetFullPath($agentsMd)) { return $true }
    }
    return ((Get-FileTextRaw -Path $ClaudeMd) -cmatch '(?m)(^|\s)@(\./)?AGENTS\.md(\s|$)')
}

# Installs the block for convention $Convention, then checks what could still
# hide it from the agents (see the helpers above).
function Install-GuidelinesBlockFor {
    param([string]$Convention)
    $dest = Get-ConventionGuidelinesFile -Convention $Convention
    Write-GuidelinesBlock -Convention $Convention -Dest $dest
    if ($Convention -eq 'agents') { Write-CodexBlockNotes -AgentsMd $dest }
}

# Writes the toolkit-managed block for $Convention into guidelines file $Dest.
# Four branches, in order, plus an early exit for a destination path that exists
# but is not a file (e.g. CLAUDE.md is a directory) -- there is nothing to merge
# into, so this reports an error and exits rather than attempting anything else:
#   1. no file             -> write the block alone
#   2. markers present     -> replace only that region, no backup
#   3. legacy toolkit file -> back up, replace whole file
#   4. anything else       -> back up, add the block, keep everything they wrote
#                             (see Get-GuidelinesWithBlockAdded)
# Before 2-4, a CLAUDE.md that already gets the block through AGENTS.md (see
# Test-ClaudeMdCoveredByAgentsMd) is skipped.
function Write-GuidelinesBlock {
    param([string]$Convention, [string]$Dest)
    $label = Get-GuidelinesLabel -Convention $Convention

    if (-not (Test-Path -LiteralPath $script:SourceGuidelinesBlock)) {
        Write-ErrAndExit "guidelines-block.md not found in $($script:ResolvedVersionDir)"
    }
    $block = Get-FileTextRaw -Path $script:SourceGuidelinesBlock

    $destDir = Split-Path -Parent $Dest
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

    if (-not (Test-Path -LiteralPath $Dest)) {
        Set-FileTextRaw -Path $Dest -Text $block
        Write-Info "  Installed: $Dest"
        Write-ChangeMarker -Action 'created' -Type 'file' -Path $Dest
        Write-Info "  Project guidelines installed for $label"
        return
    }

    if (-not (Test-Path -LiteralPath $Dest -PathType Leaf)) {
        Write-ErrAndExit "cannot merge guidelines into $Dest`: it exists but is not a file"
    }

    if ($Convention -eq 'claude' -and (Test-ClaudeMdCoveredByAgentsMd -ClaudeMd $Dest)) {
        Write-Info "  Skipped: $Dest (imports AGENTS.md, which already carries the block)"
        Write-Info "  Project guidelines reach $label through AGENTS.md"
        return
    }

    $text  = Get-FileTextRaw -Path $Dest
    $range = Get-BlockRange -Text $text

    if ($null -ne $range) {
        $merged = $text.Substring(0, $range.Start) +
                  $block.TrimEnd("`r", "`n") +
                  $text.Substring($range.End)
        if ($merged -ceq $text) {
            Write-Info "  Unchanged: $Dest"
            Write-Info "  Project guidelines already up to date for $label"
            return
        }
        Set-FileTextAtomic -Dest $Dest -Text $merged
        Write-Info "  Updated: $Dest"
        Write-ChangeMarker -Action 'updated' -Type 'file' -Path $Dest
        Write-Info "  Project guidelines installed for $label"
        return
    }

    # Branches 3 and 4 rewrite content the toolkit does not own, so they always
    # back up, regardless of -BackupExistingFiles (issue #17).
    $backupName = Get-DedupBackupName -Path $Dest
    $backupPath = Join-Path $destDir $backupName
    Copy-Item -LiteralPath $Dest -Destination $backupPath -ErrorAction Stop
    Write-ChangeMarker -Action 'backed-up' -Type 'file' -Path $backupPath

    if (Test-LegacyGuidelines -Text $text) {
        Set-FileTextAtomic -Dest $Dest -Text $block
    } else {
        Set-FileTextAtomic -Dest $Dest -Text (Get-GuidelinesWithBlockAdded -Dest $Dest -Text $text -Block $block)
    }

    Write-Info "  Updated: $Dest (backup: $backupName)"
    Write-ChangeMarker -Action 'updated' -Type 'file' -Path $Dest
    Write-Info "  Project guidelines installed for $label"
}

# Branch 4: $Text of $Dest with $Block added, everything they wrote kept. An
# AGENTS.md gets it on top (Codex reads only its first 32 KiB), after a leading
# UTF-8 BOM that stays the first bytes; any other file gets it at the end.
function Get-GuidelinesWithBlockAdded {
    param([string]$Dest, [string]$Text, [string]$Block)
    if ([System.IO.Path]::GetFileName($Dest) -ceq 'AGENTS.md') {
        if ($Text.StartsWith($script:RawBom, [System.StringComparison]::Ordinal)) {
            return $script:RawBom + $Block + "`n" + $Text.Substring($script:RawBom.Length)
        }
        return $Block + "`n" + $Text
    }
    $prefix = $Text
    if ($prefix.Length -gt 0 -and -not $prefix.EndsWith("`n")) { $prefix += "`n" }
    return $prefix + "`n" + $Block
}

# Installs the block for every convention in $ConventionList, agents before
# claude so Test-ClaudeMdCoveredByAgentsMd sees AGENTS.md in its final state
# whatever order they were given in. -Lenient keeps going after a failed one
# (wizard).
function Install-GuidelinesBlocks {
    param([string[]]$ConventionList, [switch]$Lenient)
    foreach ($c in @($script:AllConventions | Where-Object { $ConventionList -contains $_ })) {
        if ($Lenient) {
            try { Install-GuidelinesBlockFor -Convention $c } catch { Write-Info "error: $($_.Exception.Message)" }
        } else {
            Install-GuidelinesBlockFor -Convention $c
        }
    }
}

function Invoke-CmdAgentsMd {
    $conventionList = Resolve-ConventionsCsv -Csv (Get-ConventionsArg) -Subcommand 'agents-md'
    Write-Info "Project guidelines target directory: $((Get-Location).Path)"
    Initialize-Tarball
    Install-GuidelinesBlocks -ConventionList $conventionList
}

# =================================================================
# MCP registration (shared by mcp, mcp-jetbrains, mcp-context7, playwright)
# =================================================================
#
# Servers are written straight into each agent's config file. Local scope
# writes the project files, global scope the user files:
#
#   agent           local                  global
#   claude          .mcp.json              ~\.claude.json via `claude mcp add`
#   codex           .codex\config.toml     $env:CODEX_HOME (default ~\.codex)\config.toml
#   opencode        opencode.json          $env:XDG_CONFIG_HOME (default ~\.config)\opencode\opencode.json
#   junie           .junie\mcp\mcp.json    $env:JUNIE_HOME (default ~\.junie)\mcp\mcp.json
#
# With claude, Claude Desktop is set up too when it is installed (see
# Write-ClaudeDesktopServer): claude_desktop_config.json, user level only.
#
# ~\.claude.json is Claude Code's own state file, so it is changed only through
# the claude CLI. Every other file is merged in place, with no agent CLI needed
# (Studio runs this from the IDE process): other servers and keys are kept, an
# unchanged file is not rewritten, and a file that cannot be parsed is left
# alone and the step fails.

function Get-UserConfigHome {
    if ($env:XDG_CONFIG_HOME) { return $env:XDG_CONFIG_HOME }
    return (Join-Path $script:UserHome '.config')
}

# Returns the Claude Desktop config files to write, none when Claude Desktop
# has no config folder here (not installed, or never started). On Windows the
# Store (MSIX) build reads its own copy of %APPDATA%\Claude under its package
# folder, so every existing config is updated; without one, the file is created
# in the first existing folder, package folders first. A package folder never
# gets a new file while %APPDATA%\Claude has one: it would shadow that file.
function Get-ClaudeDesktopConfigFiles {
    $name = 'claude_desktop_config.json'
    if (-not $script:IsWindowsHost) {
        $dir = if (Get-Variable -Name IsMacOS -ValueOnly -ErrorAction SilentlyContinue) {
            Join-Path $script:UserHome 'Library/Application Support/Claude'
        } else {
            Join-Path (Get-UserConfigHome) 'Claude'
        }
        if (Test-Path -LiteralPath $dir -PathType Container) { return (Join-Path $dir $name) }
        return
    }
    $dirs = @()
    if ($env:LOCALAPPDATA) {
        foreach ($pkg in 'Claude_pzs8sxrjxfjjc', 'AnthropicPBC.Claude_fnn82j28hfe8t') {
            $dirs += [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Packages', $pkg, 'LocalCache', 'Roaming', 'Claude')
        }
    }
    if ($env:APPDATA) { $dirs += Join-Path $env:APPDATA 'Claude' }
    $existing = @($dirs | ForEach-Object { Join-Path $_ $name } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($existing.Count -gt 0) { return $existing }
    $dir = $dirs | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
    if ($dir) { return (Join-Path $dir $name) }
}

# Returns the MCP config file of $Agent for $Scope (see the table above).
function Get-McpConfigFile {
    param([string]$Agent, [string]$Scope)
    if ($Scope -eq 'local') {
        $proj = (Get-Location).Path
        switch ($Agent) {
            'claude'   { return (Join-Path $proj '.mcp.json') }
            'codex'    { return [System.IO.Path]::Combine($proj, '.codex', 'config.toml') }
            'opencode' { return (Join-Path $proj 'opencode.json') }
            'junie'    { return [System.IO.Path]::Combine($proj, '.junie', 'mcp', 'mcp.json') }
        }
    } else {
        switch ($Agent) {
            'codex' {
                $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $script:UserHome '.codex' }
                return (Join-Path $codexHome 'config.toml')
            }
            'opencode' { return [System.IO.Path]::Combine((Get-UserConfigHome), 'opencode', 'opencode.json') }
            'junie' {
                $junieHome = if ($env:JUNIE_HOME) { $env:JUNIE_HOME } else { Join-Path $script:UserHome '.junie' }
                return [System.IO.Path]::Combine($junieHome, 'mcp', 'mcp.json')
            }
        }
    }
    throw "no MCP config file for agent '$Agent' at scope '$Scope'"
}

# Writes config $Raw (Get-FileTextRaw representation) to $File through a temp
# file and logs whether it was created or updated; with -Unchanged it only
# says so. A new file is 0600 on Unix with -Private; see Set-FileTextAtomic for
# existing files and links. While $script:McpPrivate is set (the entry carries
# the Context7 key) the file ends up usable by its owner only, whatever mode
# it had.
function Save-McpConfig {
    param([string]$File, [string]$Raw, [switch]$Unchanged, [switch]$Private)
    if ($Unchanged) {
        Write-Info "  Unchanged: $File"
    } else {
        $existed = Test-Path -LiteralPath $File
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($File))
        Set-FileTextAtomic -Dest $File -Text $Raw -TempPrefix '.jmix-mcp.' -Private:$Private
        if ($existed) {
            Write-Info "  Updated: $File"
            Write-ChangeMarker -Action 'updated' -Type 'file' -Path $File
        } else {
            Write-Info "  Created: $File"
            Write-ChangeMarker -Action 'created' -Type 'file' -Path $File
        }
        $script:ConfigChanged = $true
    }
    if ($script:McpPrivate) { Protect-OwnerOnly -Path $File }
}

# The text of config $File, $null when there is no such file: decoded as
# UTF-8 (a BOM honoured and dropped), or with -Raw as Get-FileTextRaw does. A
# file that cannot be read fails the step and is left unchanged, never replaced.
function Read-McpConfigText {
    param([string]$File, [switch]$Raw)
    if ((Test-Path -LiteralPath $File) -and -not (Test-Path -LiteralPath $File -PathType Leaf)) {
        throw "cannot update ${File}: it exists but is not a regular file"
    }
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $null }
    try {
        if ($Raw) { return (Get-FileTextRaw -Path $File) }
        return [System.IO.File]::ReadAllText($File, [System.Text.Encoding]::UTF8)
    } catch { throw "cannot read ${File}; it was left unchanged" }
}

# Parses $Text as a JSON object; $null when it is anything else. Comments are
# refused too: pwsh's parser skips them, so a rewrite would silently drop them.
function ConvertFrom-JsonObject {
    param([string]$Text)
    if (($Text -replace '"(?:[^"\\]|\\.)*"', '""') -match '//|/\*') { return $null }
    if ($Text -notmatch '^\s*\{') { return $null }
    $options = @{}
    # pwsh 7.5+ would otherwise turn date-like strings into dates.
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $options['DateKind'] = 'String' }
    try { $value = ConvertFrom-Json -InputObject $Text @options } catch { return $null }
    if ($value -is [System.Management.Automation.PSCustomObject]) { return $value }
    return $null
}

# Sets server $Name = $Entry under the $Root object of JSON file $File. A
# missing or blank file starts as {}; a UTF-8 BOM is tolerated, and the result
# is UTF-8 without one. The file is not rewritten when the result serializes
# the same as what it holds.
function Set-McpJsonEntry {
    param([string]$File, [string]$Root, [string]$Name, [object]$Entry, [switch]$Private)
    $refusal = "cannot update ${File}: it is not plain JSON (comments are not supported). Add the `"$Name`" server to it manually, see README."
    $text = Read-McpConfigText -File $File
    $config = [PSCustomObject]@{}
    $before = $null
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        $config = ConvertFrom-JsonObject -Text $text
        if ($null -eq $config) { throw $refusal }
        $before = ConvertTo-Json -InputObject $config -Depth 100
    }
    $servers = $config.PSObject.Properties[$Root]
    if ($null -eq $servers) {
        Add-Member -InputObject $config -NotePropertyName $Root -NotePropertyValue ([PSCustomObject]@{})
        $servers = $config.PSObject.Properties[$Root]
    } elseif ($null -eq $servers.Value) {
        $servers.Value = [PSCustomObject]@{}
    }
    if ($servers.Value -isnot [System.Management.Automation.PSCustomObject]) { throw $refusal }
    # Assigning in place keeps the server's position among the others.
    $current = $servers.Value.PSObject.Properties[$Name]
    if ($current) { $current.Value = $Entry }
    else { Add-Member -InputObject $servers.Value -NotePropertyName $Name -NotePropertyValue $Entry }
    $after = ConvertTo-Json -InputObject $config -Depth 100
    $json = ($after -replace '\r\n', "`n") + "`n"
    Save-McpConfig -File $File -Raw $script:BytePreservingEncoding.GetString([System.Text.Encoding]::UTF8.GetBytes($json)) `
        -Unchanged:($after -ceq $before) -Private:$Private
}

function Test-TomlKeyWithin {
    param([string]$Key, [string]$Table)
    return ($Key -ceq $Table -or $Key.StartsWith("$Table.", [System.StringComparison]::Ordinal))
}

# A TOML key or header without blanks and quotes: [ "a" . 'b' ] -> a.b
function ConvertTo-TomlKey {
    param([string]$Text)
    return ($Text -replace '[ \t"'']', '')
}

# The key of TOML header line $Line: [a.b] or [[a.b]] -> a.b
function Get-TomlHeaderKey {
    param([string]$Line)
    return (ConvertTo-TomlKey -Text (($Line -replace '^[ \t]*\[+', '') -replace '\].*$', ''))
}

# Returns $Lines with table [$Table] (and its sub-tables)
# replaced by $Body where it first stands, or appended when absent; $null when
# $Table is also defined another way (dotted keys, or inline in itself or in a
# parent), which this edit cannot replace. Comments and blank lines between the
# replaced table and the next header stay: they usually introduce that table.
function Get-TomlWithTable {
    param([string[]]$Lines, [string]$Table, [string[]]$Body)
    $out     = New-Object System.Collections.Generic.List[string]
    $pending = New-Object System.Collections.Generic.List[string]
    $skip    = $false
    $done    = $false
    $current = ''
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line  = $Lines[$i]
        $probe = $line
        if ($i -eq 0 -and $line.StartsWith($script:RawBom, [System.StringComparison]::Ordinal)) {
            $probe = $line.Substring($script:RawBom.Length)
        }
        if ($probe -match '^[ \t]*\[') {
            $header = Get-TomlHeaderKey -Line $probe
            if ($skip) { $out.AddRange($pending); $pending.Clear() }
            $skip = Test-TomlKeyWithin -Key $header -Table $Table
            if (-not $skip) { $current = $header; $out.Add($line); continue }
            if (-not $done) {
                # A BOM before the replaced first header stays the first bytes.
                $out.Add($line.Substring(0, $line.Length - $probe.Length) + "[$Table]")
                $out.AddRange($Body)
                $done = $true
            }
            continue
        }
        if ($skip) {
            if ($probe -match '^[ \t]*(#.*)?$') { $pending.Add($line) } else { $pending.Clear() }
            continue
        }
        if ($probe.Contains('=')) {
            $key  = ConvertTo-TomlKey -Text ($probe -replace '=.*$', '')
            $full = if ($current) { "$current.$key" } else { $key }
            if ((Test-TomlKeyWithin -Key $full -Table $Table) -or (Test-TomlKeyWithin -Key $Table -Table $full)) { return $null }
        }
        $out.Add($line)
    }
    if ($skip) { $out.AddRange($pending) }
    # Trailing blank lines go.
    $last = $out.Count
    while ($last -gt 0 -and $out[$last - 1] -match '^[ \t]*$') { $last-- }
    $result = @($out.GetRange(0, $last))
    if (-not $done) {
        if ($last -gt 0) { $result += '' }
        $result += "[$Table]"
        $result += $Body
    }
    return , [string[]]$result
}

# Sets table [$Table] of TOML file $File to $Body lines (see Get-TomlWithTable),
# in the file's line-ending style. Fails, leaving the file alone, when $Table is
# defined another way.
function Set-McpTomlTable {
    param([string]$File, [string]$Table, [string[]]$Body, [switch]$Private, [switch]$Scan)
    $original = Read-McpConfigText -File $File -Raw
    # shortcut: refuse triple-quoted content; use a TOML parser to edit it safely.
    # -Scan only checks how [$Table] is defined, for a file that is read but
    # not written: triple-quoted strings elsewhere do not matter then.
    if (-not $Scan -and $original -match '"{3}|''{3}') {
        throw "cannot update ${File}: multi-line TOML strings are not supported. Add [$Table] manually, see README."
    }
    $newline = "`n"
    $lines = @()
    if ($original) {
        if ($original.Contains("`r`n")) { $newline = "`r`n" }
        $lines = @(($original -replace '\n\z', '') -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
    }
    $result = Get-TomlWithTable -Lines $lines -Table $Table -Body $Body
    if ($null -eq $result) {
        if ($Scan) {
            throw "cannot check ${File}: [$Table] is defined there in a form this installer cannot read. Define it as an explicit [$Table] table, or remove it, then re-run."
        }
        throw "cannot update ${File}: [$Table] is defined there in a form this installer does not edit. Change it manually, see README."
    }
    if ($Scan) { return }
    $text = ($result -join $newline) + $newline
    Save-McpConfig -File $File -Raw $text -Unchanged:($text -ceq $original) -Private:$Private
}

# Returns 'url' or 'command' -- the transport of table [$Table] in Codex config
# $File -- or $null when the file or the table is absent.
function Get-CodexTransport {
    param([string]$File, [string]$Table)
    $text = Read-McpConfigText -File $File -Raw
    if (-not $text) { return $null }
    if ($text.StartsWith($script:RawBom, [System.StringComparison]::Ordinal)) { $text = $text.Substring($script:RawBom.Length) }
    $inTable = $false
    foreach ($line in $text -split "`n") {
        if ($line -match '^[ \t]*\[') {
            $inTable = ((Get-TomlHeaderKey -Line $line) -ceq $Table)
        } elseif ($inTable -and $line.Contains('=')) {
            $key = ConvertTo-TomlKey -Text ($line -replace '=.*$', '')
            if ($key -cin @('url', 'command')) { return $key }
        }
    }
    return $null
}

# Codex merges [mcp_servers.X] of the user config with the project configs of
# the current directory up to its git root (the current directory alone outside
# a repository), key by key, and refuses its whole configuration when the
# result mixes url (HTTP) and command (stdio). Throws when one of those layers,
# other than the one written at $Scope, defines the server with the other
# transport; they are only read, never changed.
function Test-CodexLayers {
    param([string]$Scope, [string]$Name, [string[]]$Body)
    $own = Get-McpConfigFile -Agent 'codex' -Scope $Scope
    $cwd = (Get-Location).Path
    $root = $cwd
    while (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
        $parent = Split-Path -Parent $root
        if (-not $parent) { $root = $cwd; break }
        $root = $parent
    }
    Test-CodexLayer -Own $own -File (Get-McpConfigFile -Agent 'codex' -Scope 'global') -Name $Name -Body $Body
    $dir = $cwd
    while ($true) {
        Test-CodexLayer -Own $own -File ([System.IO.Path]::Combine($dir, '.codex', 'config.toml')) -Name $Name -Body $Body
        if ($dir -eq $root) { break }
        $dir = Split-Path -Parent $dir
    }
}

# Throws when Codex config $File -- unless it is $Own, the file being written
# (also the user config when run from the user's home, even when a symlink in
# the path makes the two spellings differ) -- defines server $Name with
# another transport than $Body. The marker of Test-SameDirectory goes into the
# folder of $Own, which this step writes anyway.
function Test-CodexLayer {
    param([string]$Own, [string]$File, [string]$Name, [string[]]$Body)
    if ($File -eq $Own -or (Test-SameDirectory -Path (Split-Path -Parent $Own) -Other (Split-Path -Parent $File))) { return }
    Set-McpTomlTable -File $File -Table "mcp_servers.$Name" -Body $Body -Scan
    $theirs = Get-CodexTransport -File $File -Table "mcp_servers.$Name"
    $mine = if ($Body[0] -clike 'url*') { 'url' } else { 'command' }
    if (-not $theirs -or $theirs -eq $mine) { return }
    if ($Name -eq 'jetbrains' -and $script:JbGuessed) {
        throw "$File defines [mcp_servers.jetbrains] with another transport, and IntelliJ IDEA is not reachable to tell which one it serves. Start it with its MCP server enabled and re-run."
    }
    throw "$File defines [mcp_servers.$Name] with another transport, which Codex cannot merge with $Own. Remove or change that table, then re-run."
}

# The claude CLI as an application (claude.exe / claude.cmd, or the executable
# on macOS/Linux) before anything else: npm's claude.ps1 shim may be blocked
# by the execution policy, and PowerShell drops a literal '--' passed to it.
# Off PATH, it is looked up where Claude Code's installers put it: an IDE
# started from the desktop often lacks ~\.local\bin on PATH.
function Get-ClaudeCli {
    $apps = @(Get-Command claude -CommandType Application -All -ErrorAction SilentlyContinue)
    if ($script:IsWindowsHost) { $apps = @($apps | Where-Object { $_.Extension -in '.exe', '.cmd', '.bat' }) }
    if ($apps.Count -gt 0) { return $apps[0] }
    $onPath = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return $onPath }
    $exe = if ($script:IsWindowsHost) { 'claude.exe' } else { 'claude' }
    foreach ($dir in '.local/bin', '.claude/local') {
        $path = [System.IO.Path]::Combine($script:UserHome, $dir, $exe)
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return (Get-Command -Name $path -CommandType Application -ErrorAction SilentlyContinue)
        }
    }
}

# Runs $Command with all its output discarded and returns its exit code.
function Invoke-NativeQuiet {
    param([System.Management.Automation.CommandInfo]$Command, [string[]]$CliArgs)
    # Windows PowerShell turns redirected stderr into errors, which 'Stop'
    # would make terminating; the exit code is what counts here.
    $ErrorActionPreference = 'Continue'
    & $Command @CliArgs *> $null
    return $LASTEXITCODE
}

# Registers a Claude Code user-scope server through the claude CLI. `mcp add`
# exits 1 when the name exists, so any entry is removed first. Its output is
# discarded: it echoes the command line, the Context7 key included.
function Add-ClaudeUserMcp {
    param([string]$Name, [string[]]$CliArgs)
    $claude = Get-ClaudeCli
    if ($null -eq $claude) {
        Write-Info "  Skipped: 'claude' CLI not found on PATH, in ~/.local/bin or in ~/.claude/local. Install Claude Code and re-run."
        return
    }
    $null = Invoke-NativeQuiet -Command $claude -CliArgs @('mcp', 'remove', '--scope', 'user', $Name)
    if ((Invoke-NativeQuiet -Command $claude -CliArgs (@('mcp', 'add') + $CliArgs)) -ne 0) {
        throw "claude mcp add $Name failed"
    }
    Write-Info "  Registered $Name in the Claude Code user config"
}

# Writes MCP server $Name for $Agent at $Scope. $Entry is the server object for
# a JSON config, or the TOML table body lines for codex. For claude at global
# scope $CliArgs (the arguments of `claude mcp add`) are used instead.
function Write-McpServer {
    param([string]$Agent, [string]$Scope, [string]$Name, [object]$Entry, [string[]]$CliArgs)
    if ($Agent -eq 'claude' -and $Scope -eq 'global') {
        Add-ClaudeUserMcp -Name $Name -CliArgs $CliArgs
        return
    }
    $file = Get-McpConfigFile -Agent $Agent -Scope $Scope
    # A new user config is private (it may get the Context7 key later), and so
    # is any new file that gets it now.
    $isPrivate = ($Scope -eq 'global' -or $script:McpPrivate)
    if ($Agent -eq 'codex') {
        Test-CodexLayers -Scope $Scope -Name $Name -Body $Entry
        Set-McpTomlTable -File $file -Table "mcp_servers.$Name" -Body $Entry -Private:$isPrivate
    } else {
        $root = if ($Agent -eq 'opencode') { 'mcp' } else { 'mcpServers' }
        Set-McpJsonEntry -File $file -Root $root -Name $Name -Entry $Entry -Private:$isPrivate
    }
    if ($script:McpPrivate -and $Scope -eq 'local') {
        $script:McpKeyFiles += $file.Substring((Get-Location).Path.Length).TrimStart('\', '/')
    }
}

# Claude Desktop takes stdio servers only and has no project scope. It is set
# up together with claude whenever it is installed here, i.e. a config folder
# exists (see Get-ClaudeDesktopConfigFiles); otherwise nothing is written.
function Write-ClaudeDesktopServer {
    param([string]$Name, [object]$Entry)
    $script:ConfigChanged = $false
    foreach ($file in @(Get-ClaudeDesktopConfigFiles)) {
        Set-McpJsonEntry -File $file -Root 'mcpServers' -Name $Name -Entry $Entry -Private
    }
    if ($script:ConfigChanged) {
        Write-Info '  Quit Claude Desktop completely (not just its window) and start it again to load the change.'
    }
}

# True when claude is among $AgentList and Claude Desktop is installed here.
function Test-DesktopSelected {
    param([string[]]$AgentList)
    return (($AgentList -contains 'claude') -and (@(Get-ClaudeDesktopConfigFiles).Count -gt 0))
}

# Runs MCP step $Step (a function taking -Agent plus $StepParams) for every
# agent. A failing agent is reported and marks the run failed; the agents
# after it still run.
function Invoke-McpForAgents {
    param([string[]]$AgentList, [string]$Step, [hashtable]$StepParams = @{})
    foreach ($agent in $AgentList) {
        Write-Info ''
        try {
            & $Step -Agent $agent @StepParams
        } catch {
            Write-Err $_.Exception.Message
            $script:McpFailed = $true
        }
    }
}

# Prints what the user still has to do for the configs just written.
function Write-McpFollowups {
    param([string[]]$AgentList, [string]$McpScope)
    if ($McpScope -ne 'local') { return }
    Write-Info ''
    if ($AgentList -contains 'claude') {
        Write-Info 'Claude Code asks to approve the servers in .mcp.json on its next start in this project.'
    }
    if ($AgentList -contains 'codex') {
        Write-Info "Codex reads .codex/config.toml only in trusted projects: accept its 'trust this folder' prompt. The Codex desktop app ignores project MCP servers; use -Scope global for it."
    }
    if ($script:McpKeyFiles.Count -gt 0) {
        Write-Info "The Context7 API key is now in $($script:McpKeyFiles -join ' '): keep these files out of version control."
    }
}

# The options that only some MCP subcommands take are refused by the others.
function Assert-McpArgs {
    param([string]$Subcommand, [switch]$AllowServers, [switch]$AllowKey)
    if ($Servers -and -not $AllowServers) { Write-ErrAndExit "${Subcommand}: unknown argument: -Servers" }
    if ($Context7Key -and -not $AllowKey) { Write-ErrAndExit "${Subcommand}: unknown argument: -Context7Key" }
}

# =================================================================
# MCP install - JetBrains
# =================================================================

# IntelliJ 2026.1+ serves Streamable HTTP at /stream; 2025.2/2025.3 serve only
# SSE at /sse and answer 404 there. A HEAD request tells them apart without
# opening an MCP session. When the IDE does not answer (server disabled, IDE
# closed), assume 2026.1+ and say so.
function Resolve-JetbrainsTransport {
    $code = 0
    # HttpWebRequest works the same on Windows PowerShell 5.1 and pwsh 7. No
    # proxy: one set in HTTP_PROXY would answer instead of the IDE.
    $request = [System.Net.WebRequest]::Create("http://127.0.0.1:$($script:JbPort)/stream")
    $request.Method  = 'HEAD'
    $request.Proxy   = $null
    $request.Timeout = 3000
    try {
        $response = $request.GetResponse()
        $code = [int]$response.StatusCode
        $response.Close()
    } catch {
        # An HTTP error status arrives as a WebException carrying the response
        # (wrapped by PowerShell); there is none when nothing listens.
        $ex = $_.Exception
        while ($ex -and $ex -isnot [System.Net.WebException]) { $ex = $ex.InnerException }
        if ($ex -and $ex.Response) {
            $code = [int]$ex.Response.StatusCode
            $ex.Response.Close()
        }
    }
    $script:JbTransport = 'stream'
    $script:JbGuessed = ($code -eq 0)
    if ($code -eq 404) {
        $script:JbTransport = 'sse'
        Write-Info "IntelliJ IDEA MCP server on port $($script:JbPort) has no /stream endpoint (IntelliJ IDEA before 2026.1): using SSE."
    } elseif ($code -eq 0) {
        Write-Info "IntelliJ IDEA MCP server is not reachable on port $($script:JbPort); assuming IntelliJ IDEA 2026.1+."
        Write-Info 'Enable it in Settings | Tools | MCP Server. On IntelliJ IDEA 2025.x, re-run this step once it is enabled.'
    }
}

function Install-JetbrainsFor {
    param([string]$Agent, [string]$Scope)
    $base = "http://127.0.0.1:$($script:JbPort)"
    Write-Info "[JetBrains MCP] $(Get-AgentLabel -Agent $Agent)"
    if ($Agent -eq 'junie') {
        Write-Info '  Junie runs inside IntelliJ IDEA and already has native IDE access. No JetBrains MCP needed.'
        return
    }
    $isSse = ($script:JbTransport -eq 'sse')
    $url = if ($isSse) { "$base/sse" } else { "$base/stream" }
    switch ($Agent) {
        'claude' {
            $type = if ($isSse) { 'sse' } else { 'http' }
            try {
                Write-McpServer -Agent $Agent -Scope $Scope -Name 'jetbrains' -Entry ([PSCustomObject][ordered]@{ type = $type; url = $url }) `
                    -CliArgs @('--scope', 'user', '--transport', $type, 'jetbrains', $url)
            } finally {
                # Claude Desktop has no HTTP transport for local servers: always the bridge.
                Write-ClaudeDesktopServer -Name 'jetbrains' -Entry ([PSCustomObject][ordered]@{
                    command = 'npx'; args = @('-y', 'mcp-remote', "$base/sse", '--transport', 'sse-only') })
            }
        }
        'codex' {
            # Codex has no SSE transport: the same stdio bridge on 2025.x.
            $body = @("url = `"$url`"")
            if ($isSse) { $body = @('command = "npx"', "args = [`"-y`", `"mcp-remote`", `"$url`", `"--transport`", `"sse-only`"]", 'startup_timeout_sec = 60') }
            Write-McpServer -Agent $Agent -Scope $Scope -Name 'jetbrains' -Entry $body
        }
        'opencode' {
            Write-McpServer -Agent $Agent -Scope $Scope -Name 'jetbrains' -Entry ([PSCustomObject][ordered]@{ type = 'remote'; url = $url; enabled = $true })
        }
    }
}

function Install-McpJetbrains {
    param([string[]]$AgentList, [string]$McpScope)
    Write-Info ''
    Resolve-JetbrainsTransport
    Invoke-McpForAgents -AgentList $AgentList -Step 'Install-JetbrainsFor' -StepParams @{ Scope = $McpScope }
    if (Test-DesktopSelected -AgentList $AgentList) {
        Write-NpxNote -What "Claude Desktop's JetBrains MCP bridge"
    } elseif ($AgentList -contains 'codex' -and $script:JbTransport -eq 'sse') {
        Write-NpxNote -What "Codex's JetBrains MCP bridge"
    }
}

function Invoke-CmdMcpJetbrains {
    Assert-McpArgs -Subcommand 'mcp-jetbrains'
    $agentList = Resolve-AgentsCsv -Csv $Agents -Subcommand 'mcp-jetbrains'
    $mcpScope = Resolve-Scope -Scope $Scope -Default 'local' -Subcommand 'mcp-jetbrains'
    $script:McpKeyFiles = @()
    Install-McpJetbrains -AgentList $agentList -McpScope $mcpScope
    Write-McpFollowups -AgentList $agentList -McpScope $mcpScope
}

# =================================================================
# MCP install - Context7
# =================================================================

# False for an empty key or one that would need escaping: the key is spliced
# into JSON, TOML and an HTTP header as is.
function Test-Context7Key {
    param([string]$Key)
    return ($Key -cmatch '^[A-Za-z0-9._-]+\z')
}

function Install-Context7For {
    param([string]$Agent, [string]$Scope, [string]$Key)
    $url = $script:Context7Url
    Write-Info "[Context7 MCP] $(Get-AgentLabel -Agent $Agent)"
    switch ($Agent) {
        'claude' {
            try {
                Write-McpServer -Agent $Agent -Scope $Scope -Name 'context7' -Entry ([PSCustomObject][ordered]@{
                    type = 'http'; url = $url; headers = [PSCustomObject]@{ Authorization = "Bearer $Key" } }) `
                    -CliArgs @('--scope', 'user', '--transport', 'http', 'context7', $url, '--header', "Authorization: Bearer $Key")
            } finally {
                Write-ClaudeDesktopServer -Name 'context7' -Entry (New-Context7StdioEntry -Key $Key)
            }
        }
        'codex' {
            Write-McpServer -Agent $Agent -Scope $Scope -Name 'context7' `
                -Entry @("url = `"$url`"", "http_headers = { Authorization = `"Bearer $Key`" }")
        }
        'opencode' {
            Write-McpServer -Agent $Agent -Scope $Scope -Name 'context7' -Entry ([PSCustomObject][ordered]@{
                type = 'remote'; url = $url; headers = [PSCustomObject]@{ Authorization = "Bearer $Key" }; enabled = $true })
        }
        default {
            Write-McpServer -Agent $Agent -Scope $Scope -Name 'context7' -Entry (New-Context7StdioEntry -Key $Key)
        }
    }
}

# Context7 for Junie and Claude Desktop: stdio, the key in the environment, not in argv.
function New-Context7StdioEntry {
    param([string]$Key)
    return [PSCustomObject][ordered]@{
        command = 'npx'; args = @('-y', '@upstash/context7-mcp'); env = [PSCustomObject]@{ CONTEXT7_API_KEY = $Key } }
}

# Registers Context7 for $AgentList at $McpScope with $Key, asking for it when
# it is empty; 'skip' skips the step (Studio's MCP step has to pass a value).
function Install-McpContext7 {
    param([string[]]$AgentList, [string]$McpScope, [string]$Key)
    Write-Info ''
    if ($Key -ceq 'skip') {
        Write-Info '[Context7 MCP] Skipped: no API key given.'
        return
    }
    if (-not $Key) {
        # Without a console (-NonInteractive) Read-Host throws: treat it as no key.
        try { $Key = Read-Prompt -Message 'Context7 API key' -Default '' } catch { $Key = '' }
        if (-not $Key) { Write-Err 'Context7 API key is required'; $script:McpFailed = $true; return }
    }
    if (-not (Test-Context7Key -Key $Key)) {
        Write-Err "Context7 API key may contain only letters, digits, '.', '_' and '-'"
        $script:McpFailed = $true
        return
    }
    # The entries carry the key: see Save-McpConfig.
    $script:McpPrivate = $true
    try {
        Invoke-McpForAgents -AgentList $AgentList -Step 'Install-Context7For' -StepParams @{ Scope = $McpScope; Key = $Key }
    } finally {
        $script:McpPrivate = $false
    }
    if ($AgentList -contains 'junie') {
        Write-NpxNote -What 'Context7 for Junie'
    } elseif (Test-DesktopSelected -AgentList $AgentList) {
        Write-NpxNote -What 'Context7 for Claude Desktop'
    }
}

function Invoke-CmdMcpContext7 {
    Assert-McpArgs -Subcommand 'mcp-context7' -AllowKey
    $agentList = Resolve-AgentsCsv -Csv $Agents -Subcommand 'mcp-context7'
    $mcpScope = Resolve-Scope -Scope $Scope -Default 'local' -Subcommand 'mcp-context7'
    $script:McpKeyFiles = @()
    Install-McpContext7 -AgentList $agentList -McpScope $mcpScope -Key $Context7Key
    Write-McpFollowups -AgentList $agentList -McpScope $mcpScope
}

# =================================================================
# MCP install - Playwright
# =================================================================

function Install-PlaywrightFor {
    param([string]$Agent, [string]$Scope)
    $pkg = $script:PlaywrightMcpPkg
    Write-Info "[Playwright MCP] $(Get-AgentLabel -Agent $Agent)"
    switch ($Agent) {
        'claude' {
            try {
                Write-McpServer -Agent $Agent -Scope $Scope -Name 'playwright' `
                    -Entry ([PSCustomObject][ordered]@{ type = 'stdio'; command = 'npx'; args = @('-y', $pkg) }) `
                    -CliArgs @('--scope', 'user', 'playwright', '--', 'npx', '-y', $pkg)
            } finally {
                Write-ClaudeDesktopServer -Name 'playwright' -Entry ([PSCustomObject][ordered]@{ command = 'npx'; args = @('-y', $pkg) })
            }
        }
        'codex' {
            # The first npx download can outlast Codex's default startup timeout.
            Write-McpServer -Agent $Agent -Scope $Scope -Name 'playwright' `
                -Entry @('command = "npx"', "args = [`"-y`", `"$pkg`"]", 'startup_timeout_sec = 60')
        }
        'opencode' {
            Write-McpServer -Agent $Agent -Scope $Scope -Name 'playwright' `
                -Entry ([PSCustomObject][ordered]@{ type = 'local'; command = @('npx', '-y', $pkg); enabled = $true })
        }
        default {
            Write-McpServer -Agent $Agent -Scope $Scope -Name 'playwright' `
                -Entry ([PSCustomObject][ordered]@{ command = 'npx'; args = @('-y', $pkg) })
        }
    }
}

function Install-McpPlaywright {
    param([string[]]$AgentList, [string]$McpScope)
    Write-Info ''
    Invoke-McpForAgents -AgentList $AgentList -Step 'Install-PlaywrightFor' -StepParams @{ Scope = $McpScope }
    Write-NpxNote -What 'The Playwright MCP server'
}

function Invoke-CmdPlaywright {
    Assert-McpArgs -Subcommand 'playwright'
    $agentList = Resolve-AgentsCsv -Csv $Agents -Subcommand 'playwright'
    $mcpScope = Resolve-Scope -Scope $Scope -Default 'local' -Subcommand 'playwright'
    $script:McpKeyFiles = @()
    Install-McpPlaywright -AgentList $agentList -McpScope $mcpScope
    Write-McpFollowups -AgentList $agentList -McpScope $mcpScope
}

# =================================================================
# MCP install - several servers in one step (Studio's MCP step)
# =================================================================

function Invoke-McpServers {
    param([string[]]$ServerList, [string[]]$AgentList, [string]$McpScope, [string]$Key)
    $script:McpKeyFiles = @()
    foreach ($server in $ServerList) {
        switch ($server) {
            'jetbrains'  { Install-McpJetbrains -AgentList $AgentList -McpScope $McpScope }
            'context7'   { Install-McpContext7 -AgentList $AgentList -McpScope $McpScope -Key $Key }
            'playwright' { Install-McpPlaywright -AgentList $AgentList -McpScope $McpScope }
        }
    }
    Write-McpFollowups -AgentList $AgentList -McpScope $McpScope
}

function Invoke-CmdMcp {
    Assert-McpArgs -Subcommand 'mcp' -AllowServers -AllowKey
    $agentList = Resolve-AgentsCsv -Csv $Agents -Subcommand 'mcp'
    $serverList = Resolve-Csv -Csv $Servers -Subcommand 'mcp' -Option '-Servers' -Valid $script:AllMcpServers
    $mcpScope = Resolve-Scope -Scope $Scope -Default 'local' -Subcommand 'mcp'
    Invoke-McpServers -ServerList $serverList -AgentList $agentList -McpScope $mcpScope -Key $Context7Key
}

# =================================================================
# Wizard
# =================================================================

# Returns the options of $Options that the answer picks (shown through label
# script block $Label), in $Options' order, or @('skip'). The answer is a (all),
# s (skip) or option numbers separated by commas; $Default is the default answer.
# Menu text goes to the host (Write-Host): the caller captures the return value.
function Read-Choice {
    param([string]$Title, [string[]]$Options, [scriptblock]$Label, [string]$Default = 'skip')
    Write-Host ''
    Write-Host $Title
    Write-Host '  a) All'
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host ("  {0}) {1}" -f ($i + 1), (& $Label $Options[$i]))
    }
    Write-Host '  s) Skip'
    $answer = Read-Prompt -Message 'Choice (a, s, or numbers like 1,3)' -Default $Default
    if ($answer -match '^(s|skip)$') { return @('skip') }
    if ($answer -match '^(a|all)$') { return $Options }
    $picked = @()
    if ($answer -match '^[\d,\s]+$') {
        $numbers = @($answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        for ($i = 0; $i -lt $Options.Count; $i++) {
            if ($numbers -contains [string]($i + 1)) { $picked += $Options[$i] }
        }
    }
    if ($picked.Count -eq 0) {
        Write-Host "Unrecognized choice '$answer'. Skipping."
        return @('skip')
    }
    return $picked
}

function Invoke-Wizard {
    Write-Info '=== Jmix AI Agents Toolkit ==='
    Write-Info "Working directory: $((Get-Location).Path)"

    $summaryStrings = @{
        skills     = 'skipped'
        guidelines = 'skipped'
        mcp        = 'skipped'
    }
    $resolvedScope = 'local'

    # Each Read-Choice result is wrapped in @() so a one-element return stays an
    # array: PowerShell unwraps it, and $sel[0] would index its first character.

    # Step 1: skills
    $sel = @(Read-Choice -Title '[1/3] Install Jmix skills into:' -Options $script:AllConventions `
        -Label { param($o) Get-SkillsLabel -Convention $o } -Default 'all')
    if ($sel[0] -ne 'skip') {
        $scopeAnswer = Read-Prompt -Message 'Install scope: (l)ocal project dir or (g)lobal user home' -Default 'l'
        if ($scopeAnswer -match '^(g|global)$') { $resolvedScope = 'global' }
        Initialize-Tarball
        try { Install-Skills -ConventionList $sel -Scope $resolvedScope }
        catch { Write-Info "error: $($_.Exception.Message)" }
        $summaryStrings.skills = "$($sel -join ', ') ($resolvedScope)"
    }

    # Step 2: agents-md
    $sel = @(Read-Choice -Title '[2/3] Merge Jmix coding guidelines in this directory into:' -Options $script:AllConventions `
        -Label { param($o) Get-GuidelinesLabel -Convention $o } -Default 'all')
    if ($sel[0] -ne 'skip') {
        if (Read-YesNo -Message "Target directory: $((Get-Location).Path). Proceed?" -Default 'y') {
            Initialize-Tarball
            Install-GuidelinesBlocks -ConventionList $sel -Lenient
            $summaryStrings.guidelines = $sel -join ', '
        } else {
            $summaryStrings.guidelines = 'skipped (declined)'
        }
    }

    # Step 3: MCP servers; a failed agent there is reported and the wizard moves
    # on. The scope defaults to the one chosen for the skills.
    $serverList = @(Read-Choice -Title '[3/3] Connect agents to MCP servers:' -Options $script:AllMcpServers `
        -Label { param($o) Get-ServerLabel -Server $o })
    $agentList = @('skip')
    if ($serverList[0] -ne 'skip') {
        $agentList = @(Read-Choice -Title 'For the agents:' -Options $script:AllAgents `
            -Label { param($o) Get-AgentLabel -Agent $o } -Default 'all')
    }
    if ($agentList[0] -ne 'skip') {
        $answer = Read-Prompt -Message 'Register in: (l)ocal project config or (g)lobal user config' -Default $resolvedScope.Substring(0, 1)
        $mcpScope = if ($answer -match '^(g|global)$') { 'global' } else { 'local' }
        $key = ''
        if ($serverList -contains 'context7') { $key = Read-Prompt -Message 'Context7 API key (empty to skip Context7)' -Default '' }
        if (-not $key) { $key = 'skip' }
        Invoke-McpServers -ServerList $serverList -AgentList $agentList -McpScope $mcpScope -Key $key
        $summaryStrings.mcp = "$($serverList -join ', ') for $($agentList -join ', ') ($mcpScope)"
    }

    Write-Info ''
    Write-Info '=== Setup complete ==='
    Write-Info "  Skills:      $($summaryStrings.skills)"
    Write-Info "  Guidelines:  $($summaryStrings.guidelines)"
    Write-Info "  MCP:         $($summaryStrings.mcp)"
}

# =================================================================
# Main dispatch
# =================================================================

try {
    Write-EnvDiagnostics

    # The port is spliced into URLs, JSON and TOML.
    if ($script:JbPort -notmatch '^[0-9]+\z') {
        Write-ErrAndExit "JMIX_IDE_MCP_PORT must be a port number (got '$($script:JbPort)')"
    }
    $portDigits = $script:JbPort.TrimStart('0')
    if ($portDigits.Length -eq 0 -or $portDigits.Length -gt 5 -or [int]$portDigits -gt 65535) {
        Write-ErrAndExit "JMIX_IDE_MCP_PORT must be between 1 and 65535 (got $($script:JbPort))"
    }

    switch ($Subcommand) {
        ''               { Invoke-Wizard }
        'skills'         { Invoke-CmdSkills }
        'agents-md'      { Invoke-CmdAgentsMd }
        'mcp'            { Invoke-CmdMcp }
        'mcp-jetbrains'  { Invoke-CmdMcpJetbrains }
        'mcp-context7'   { Invoke-CmdMcpContext7 }
        'playwright'     { Invoke-CmdPlaywright }
        default          { Write-ErrAndExit "unknown subcommand: $Subcommand" }
    }
    # Set only by MCP steps; the wizard reports a failed agent and goes on.
    if ($script:McpFailed -and $Subcommand) { exit 1 }
}
finally {
    if ($script:Staging -and (Test-Path $script:Staging)) {
        Remove-Item -Recurse -Force -Path $script:Staging -ErrorAction SilentlyContinue
    }
}
