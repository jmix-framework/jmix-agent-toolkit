#!/usr/bin/env pwsh
# Functional tests for install.ps1.
#
# Runs the installer's subcommands against a local checkout (via -Source) into
# an isolated temp HOME and project dir, then asserts the produced files and
# symlinks. No network and no external agent CLIs required.
#
# Every installer invocation runs in a child pwsh process whose HOME is
# redirected into the temp dir, so the real user profile is never touched and
# the installer's `exit` on error paths cannot abort this harness.
#
# Skills install succeeds without symlink privilege on Windows via a directory
# junction (and via a symbolic link on Unix), so skills assertions run
# unconditionally; on a Windows session without symlink privilege we additionally
# assert the link is a junction.
#
# Usage: pwsh tests/test_install_ps1.ps1 [-Source <dir>]
#   -Source defaults to the repository root (parent of this script's dir).

[CmdletBinding()]
param([string]$Source = '')

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Source) { $Source = (Resolve-Path (Join-Path $scriptDir '..')).Path }
$install = Join-Path $Source 'install.ps1'
if (-not (Test-Path $install)) { Write-Host "FAIL: install.ps1 not found at $install"; exit 1 }

$skill = 'jmix-create-entity'   # a stable skill folder name used for symlink checks

$work    = Join-Path ([System.IO.Path]::GetTempPath()) ("jmix-itest-" + [guid]::NewGuid().ToString('N'))
$homeDir = Join-Path $work 'home'
$proj    = Join-Path $work 'project'
New-Item -ItemType Directory -Force -Path $homeDir, $proj | Out-Null

# Redirect HOME for the child installer processes. $HOME is read-only in-process,
# so isolation is done via the environment that child processes inherit:
#   - Unix:    $HOME derives from $env:HOME
#   - Windows: $HOME derives from $env:HOMEDRIVE + $env:HOMEPATH
$env:HOME = $homeDir
$onWindows = ($IsWindows -eq $true) -or ($null -eq $IsWindows)   # $IsWindows is $null on Windows PowerShell 5.1
if ($onWindows) {
    $root = [System.IO.Path]::GetPathRoot($homeDir)
    $env:HOMEDRIVE   = $root.TrimEnd('\')
    $env:HOMEPATH    = $homeDir.Substring($env:HOMEDRIVE.Length)
    $env:USERPROFILE = $homeDir
}
Set-Location $proj

$script:failed = $false
function Check {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host "ok: $Message" }
    else { Write-Host "FAIL: $Message"; $script:failed = $true }
}

# Probe symbolic-link capability the same way install.ps1 does.
function Test-SymlinkCapable {
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ("slp-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    try {
        New-Item -ItemType SymbolicLink -Path (Join-Path $p 'l') -Target $p -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    } finally {
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$pwshPath = (Get-Process -Id $PID).Path
# Run install.ps1 in a child process; return its exit code (output discarded).
function Invoke-Installer {
    param([string[]]$InstallerArgs)
    & $pwshPath -NoProfile -File $install @InstallerArgs *> $null
    return $LASTEXITCODE
}
# Run install.ps1 in a child process; return combined stdout+stderr as a string.
function Invoke-InstallerCapture {
    param([string[]]$InstallerArgs)
    return (& $pwshPath -NoProfile -File $install @InstallerArgs 2>&1 | Out-String)
}

# ---------------------------------------------------------------------------
# 1. agents-md (project guidelines)
# ---------------------------------------------------------------------------
Check ((Invoke-Installer @('agents-md', '-Agents', 'claude,codex,opencode,junie', '-Source', $Source)) -eq 0) `
    'agents-md exits 0'
Check (Test-Path (Join-Path $proj 'CLAUDE.md'))            'agents-md: CLAUDE.md'
Check (Test-Path (Join-Path $proj 'AGENTS.md'))            'agents-md: AGENTS.md'
Check (Test-Path (Join-Path $proj '.junie/guidelines.md')) 'agents-md: .junie/guidelines.md'
$claude = Get-Content -Raw (Join-Path $proj 'CLAUDE.md')
$agents = Get-Content -Raw (Join-Path $Source 'content/AGENTS.md')
Check ($claude -eq $agents) 'agents-md: CLAUDE.md content matches v3/AGENTS.md'

# Guidelines are always backed up on overwrite (no -BackupExistingFiles), and
# repeated runs dedup the backup name: .bak, then .bak1 (issue #17).
Set-Content -LiteralPath (Join-Path $proj 'CLAUDE.md') -Value 'sentinel-1' -NoNewline
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
Check (Test-Path (Join-Path $proj 'CLAUDE.md.bak')) 'agents-md: existing CLAUDE.md backed up without flag'
Check ((Get-Content -Raw (Join-Path $proj 'CLAUDE.md.bak')) -eq 'sentinel-1') 'agents-md: .bak keeps original content'

Set-Content -LiteralPath (Join-Path $proj 'CLAUDE.md') -Value 'sentinel-2' -NoNewline
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
Check (Test-Path (Join-Path $proj 'CLAUDE.md.bak1')) 'agents-md: second backup deduped to .bak1'
Check ((Get-Content -Raw (Join-Path $proj 'CLAUDE.md.bak')) -eq 'sentinel-1') 'agents-md: dedup did not overwrite earlier .bak'
Check ((Get-Content -Raw (Join-Path $proj 'CLAUDE.md.bak1')) -eq 'sentinel-2') 'agents-md: .bak1 has correct content'

# ---------------------------------------------------------------------------
# 2. skills, local scope -- must succeed without symlink privilege
#    (junction on Windows / symlink on Unix), so the assertions run unconditionally.
# ---------------------------------------------------------------------------
Check ((Invoke-Installer @('skills', '-Agents', 'claude,codex,opencode,junie', '-Scope', 'local', '-Source', $Source)) -eq 0) `
    'skills(local) exits 0'
Check (Test-Path (Join-Path $proj '.skills'))                        'skills(local): .skills store'
Check (Test-Path (Join-Path $proj ".claude/skills/$skill/SKILL.md")) 'skills(local): claude link resolves'
Check (Test-Path (Join-Path $proj ".agents/skills/$skill/SKILL.md")) 'skills(local): agents link resolves'
Check (Test-Path (Join-Path $proj ".junie/skills/$skill/SKILL.md"))  'skills(local): junie link resolves'

# Regression guard: on a Windows session without symlink privilege the link must
# still be created -- as a junction, which needs no Developer Mode / admin.
if ($onWindows -and -not (Test-SymlinkCapable)) {
    $linkItem = Get-Item (Join-Path $proj ".claude/skills/$skill") -Force
    Check ($linkItem.LinkType -eq 'Junction') 'skills(local): falls back to junction without symlink privilege'
}

# Re-running with identical args must complete -- this is the Windows hang scenario:
# existing junctions are removed (via Directory.Delete, not a prompting Remove-Item)
# before re-linking. Links must still resolve afterwards.
Check ((Invoke-Installer @('skills', '-Agents', 'claude,codex,opencode,junie', '-Scope', 'local', '-Source', $Source)) -eq 0) `
    'skills(local): re-run exits 0 (links already exist)'
Check (Test-Path (Join-Path $proj ".claude/skills/$skill/SKILL.md")) 'skills(local): claude link still resolves after re-run'

# skills global -- store keyed by the branch (CONTENT_REF)
Check ((Invoke-Installer @('skills', '-Agents', 'claude', '-Scope', 'global', '-Source', $Source)) -eq 0) `
    'skills(global) exits 0'
Check (Test-Path (Join-Path $homeDir '.agents/.jmix/skills/v3')) 'skills(global): v3 store created'

# ---------------------------------------------------------------------------
# 3. OpenCode MCP entries (no agent CLI needed)
# ---------------------------------------------------------------------------
Check ((Invoke-Installer @('mcp-jetbrains', '-Agents', 'opencode')) -eq 0) 'mcp-jetbrains exits 0'
$cfg = Join-Path $homeDir '.config/opencode/opencode.json'
Check (Test-Path $cfg) 'mcp: opencode.json created'
$json = Get-Content -Raw $cfg | ConvertFrom-Json
Check ($json.mcp.jetbrains.url -eq 'http://localhost:64342/sse') 'mcp-jetbrains: opencode url'
# Re-running an already-configured step must stay idempotent (exit 0, no error) --
# the same guarantee the Claude path gets from its remove-then-add helper.
Check ((Invoke-Installer @('mcp-jetbrains', '-Agents', 'opencode')) -eq 0) 'mcp-jetbrains: re-run idempotent'

Check ((Invoke-Installer @('mcp-context7', '-Agents', 'opencode', '-Context7Key', 'TESTKEY')) -eq 0) 'mcp-context7 exits 0'
$json = Get-Content -Raw $cfg | ConvertFrom-Json
Check ($json.mcp.context7.command -contains 'TESTKEY') 'mcp-context7: opencode key written'

# ---------------------------------------------------------------------------
# 4. Negative cases
# ---------------------------------------------------------------------------
Check ((Invoke-Installer @('agents-md', '-Source', $Source)) -ne 0) `
    'negative: agents-md without -Agents fails'
Check ((Invoke-Installer @('skills', '-Agents', 'bogus', '-Scope', 'local', '-Source', $Source)) -ne 0) `
    'negative: unknown agent fails'
Check ((Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', (Join-Path $work 'does-not-exist'))) -ne 0) `
    'negative: missing -Source dir fails'

Set-Location $scriptDir
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:failed) {
    Write-Host 'POWERSHELL INSTALLER TESTS FAILED'
    exit 1
}
Write-Host 'ALL POWERSHELL INSTALLER TESTS PASSED'
# Reset the exit code explicitly: the last child process above (a negative case)
# leaves $LASTEXITCODE non-zero, and `shell: pwsh` exits with $LASTEXITCODE.
exit 0
