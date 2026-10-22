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
# Windows keeps Claude Desktop's config under APPDATA / LOCALAPPDATA; the other
# agents' user configs move with these variables, so none may leak in either.
$env:APPDATA      = Join-Path $homeDir 'AppData/Roaming'
$env:LOCALAPPDATA = Join-Path $homeDir 'AppData/Local'
foreach ($v in 'CODEX_HOME', 'XDG_CONFIG_HOME', 'JUNIE_HOME') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
# Nothing listens on port 9: the IDE MCP server probe sees no IDE.
$env:JMIX_IDE_MCP_PORT = '9'
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
# Run install.ps1 in a child process; return its exit code and combined output.
function Invoke-InstallerResult {
    param([string[]]$InstallerArgs)
    $out = & $pwshPath -NoProfile -File $install @InstallerArgs 2>&1 | Out-String
    return [PSCustomObject]@{ Code = $LASTEXITCODE; Output = $out }
}

# ---------------------------------------------------------------------------
# 1. agents-md (project guidelines block)
# ---------------------------------------------------------------------------
$blockPath  = Join-Path $Source 'content/guidelines-block.md'
$blockText  = [System.IO.File]::ReadAllText($blockPath)
$beginMark  = '<!-- BEGIN jmix-agent-toolkit -->'
$endMark    = '<!-- END jmix-agent-toolkit -->'
$claudeMd   = Join-Path $proj 'CLAUDE.md'
$agentsMd   = Join-Path $proj 'AGENTS.md'
$junieDir   = Join-Path $proj '.junie'

# 1a. No guidelines file yet -> the file is created holding exactly the block.
Check ((Invoke-Installer @('agents-md', '-Agents', 'claude,codex,opencode,junie', '-Source', $Source)) -eq 0) `
    'agents-md exits 0'
Check (Test-Path $claudeMd)                                'agents-md: CLAUDE.md'
Check (([System.IO.File]::ReadAllText($claudeMd)) -eq $blockText) `
    'agents-md: fresh CLAUDE.md is exactly the block'
Check (([System.IO.File]::ReadAllText($agentsMd)) -eq $blockText) `
    'agents-md: AGENTS.md shared by codex/opencode/junie is exactly the block'
# Junie reads AGENTS.md; the deprecated .junie/guidelines.md is not created.
Check (-not (Test-Path (Join-Path $junieDir 'guidelines.md'))) `
    'agents-md: Junie got no .junie/guidelines.md it would not read'

# 1a2. -Conventions names the files instead of the agents: agents (AGENTS.md)
#      and claude (CLAUDE.md); an unknown one is refused.
Remove-Item -LiteralPath $claudeMd, $agentsMd -Force
$null = Invoke-Installer @('agents-md', '-Conventions', 'agents', '-Source', $Source)
Check ((Test-Path $agentsMd) -and -not (Test-Path $claudeMd)) 'agents-md: -Conventions agents writes AGENTS.md alone'
$null = Invoke-Installer @('agents-md', '-Conventions', 'claude,agents', '-Source', $Source)
Check (([System.IO.File]::ReadAllText($claudeMd)) -eq $blockText -and ([System.IO.File]::ReadAllText($agentsMd)) -eq $blockText) `
    'agents-md: -Conventions claude,agents writes both files'
# Values are case-insensitive, as in install.sh, the agent names too.
Remove-Item -LiteralPath $claudeMd, $agentsMd -Force
$null = Invoke-Installer @('agents-md', '-Conventions', 'Claude,AGENTS', '-Source', $Source)
Check (([System.IO.File]::ReadAllText($claudeMd)) -eq $blockText -and ([System.IO.File]::ReadAllText($agentsMd)) -eq $blockText) `
    'agents-md: -Conventions is case-insensitive'
Check ((Invoke-Installer @('agents-md', '-Agents', 'Codex', '-Source', $Source)) -eq 0) 'agents-md: -Agents Codex means agents'
Check ((Invoke-Installer @('agents-md', '-Conventions', 'cursor', '-Source', $Source)) -ne 0) 'agents-md: an unknown convention fails'

# 1b. An up-to-date file is left completely alone: no rewrite, no backup (issue #22).
$mtimeBefore = (Get-Item -LiteralPath $claudeMd).LastWriteTimeUtc
Start-Sleep -Seconds 1
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
Check (-not (Test-Path "$claudeMd.bak")) 'agents-md: unchanged file not backed up'
Check ((Get-Item -LiteralPath $claudeMd).LastWriteTimeUtc -eq $mtimeBefore) `
    'agents-md: unchanged file not rewritten'

# 1b2. The same no-op guarantee holds when the checked-out block uses CRLF.
$crlfSource = Join-Path $work 'source-crlf'
$crlfContent = Join-Path $crlfSource 'content'
New-Item -ItemType Directory -Force -Path (Join-Path $crlfContent 'skills') | Out-Null
$crlfBlock = [regex]::Replace($blockText, '\r?\n', "`r`n")
[System.IO.File]::WriteAllText((Join-Path $crlfContent 'guidelines-block.md'), $crlfBlock,
    (New-Object System.Text.UTF8Encoding($false)))
Remove-Item -LiteralPath $claudeMd -Force
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $crlfSource)
$crlfHashBefore = (Get-FileHash -LiteralPath $claudeMd -Algorithm SHA256).Hash
(Get-Item -LiteralPath $claudeMd).LastWriteTimeUtc = [datetime]'2001-01-01T00:00:00Z'
$crlfMtimeBefore = (Get-Item -LiteralPath $claudeMd).LastWriteTimeUtc
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $crlfSource)
Check ((Get-FileHash -LiteralPath $claudeMd -Algorithm SHA256).Hash -eq $crlfHashBefore) `
    'agents-md: unchanged CRLF block bytes preserved'
Check ((Get-Item -LiteralPath $claudeMd).LastWriteTimeUtc -eq $crlfMtimeBefore) `
    'agents-md: unchanged CRLF block not rewritten'

# 1c. An old full AGENTS.md from a previous toolkit version is replaced whole,
#     with a backup. Heading "# Agent Instructions", and ONLY the
#     "## Skill routing" half of the content rule.
Remove-Item -LiteralPath $claudeMd -Force
Set-Content -LiteralPath $claudeMd -NoNewline -Value @"
# Agent Instructions

Use these instructions.

## Skill routing

- Persistent entity: create an entity
"@
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
Check (([System.IO.File]::ReadAllText($claudeMd)) -eq $blockText) `
    'agents-md: legacy guidelines replaced by the block (Agent Instructions + Skill routing)'
Check ((Get-Content -Raw "$claudeMd.bak") -match '# Agent Instructions') `
    'agents-md: legacy guidelines backed up (Agent Instructions + Skill routing)'

# 1c2. The other legacy heading and ONLY the other half of the content rule:
#      "# Coding Guidelines" (this toolkit's first heading) + a jmix skill name.
Remove-Item -LiteralPath $claudeMd -Force
Get-ChildItem -Path $proj -Filter 'CLAUDE.md.bak*' | Remove-Item -Force
Set-Content -LiteralPath $claudeMd -NoNewline -Value @"
# Coding Guidelines

Read jmix-create-entity before adding an entity.
"@
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
Check (([System.IO.File]::ReadAllText($claudeMd)) -eq $blockText) `
    'agents-md: legacy Coding Guidelines file replaced by the block (Coding Guidelines + skill name)'
Check ((Get-Content -Raw "$claudeMd.bak") -match '# Coding Guidelines') `
    'agents-md: legacy Coding Guidelines backed up'

# 1c3. A developer file with a legacy-looking heading but no toolkit content is
#      NOT legacy: it must be appended to, never replaced.
Remove-Item -LiteralPath $claudeMd -Force
Get-ChildItem -Path $proj -Filter 'CLAUDE.md.bak*' | Remove-Item -Force
Set-Content -LiteralPath $claudeMd -NoNewline -Value @"
# Agent Instructions

Always rebase before pushing.
"@
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
$after = [System.IO.File]::ReadAllText($claudeMd)
Check ($after -match 'Always rebase before pushing\.') `
    'agents-md: non-toolkit file with a lookalike heading not wrongly replaced'
Check ($after.Contains($beginMark)) 'agents-md: block appended to non-toolkit lookalike file'

# 1d. The developer's own file is kept and the block is appended below it.
Remove-Item -LiteralPath $claudeMd -Force
Get-ChildItem -Path $proj -Filter 'CLAUDE.md.bak*' | Remove-Item -Force
Set-Content -LiteralPath $claudeMd -Value "# My project`n`nRun the linter before every commit."
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
$after = [System.IO.File]::ReadAllText($claudeMd)
Check ($after -match 'Run the linter before every commit\.') 'agents-md: developer content kept on append'
Check ($after.Contains($beginMark))                          'agents-md: block appended'
Check (Test-Path "$claudeMd.bak")                            'agents-md: appended-to file backed up'

# 1d2. A 0-byte destination file is a degenerate "anything else" case: appended
# to with exactly one blank-line separator, never an extra leading blank line.
# Regression guard for a byte-for-byte divergence from install.sh, where an
# empty file wrongly grew an extra blank line before the block.
Remove-Item -LiteralPath $claudeMd -Force
Get-ChildItem -Path $proj -Filter 'CLAUDE.md.bak*' | Remove-Item -Force
[System.IO.File]::WriteAllText($claudeMd, '')
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
$expected1d2 = "`n" + $blockText
Check (([System.IO.File]::ReadAllText($claudeMd)) -eq $expected1d2) `
    'agents-md: empty destination file appended to byte-for-byte'
Check (Test-Path "$claudeMd.bak") 'agents-md: empty destination file backed up'

# Restore the state handed to case 1e: developer content + appended block, one
# backup, so 1e's assumptions about backup filenames still hold.
Remove-Item -LiteralPath $claudeMd -Force
Get-ChildItem -Path $proj -Filter 'CLAUDE.md.bak*' | Remove-Item -Force
Set-Content -LiteralPath $claudeMd -Value "# My project`n`nRun the linter before every commit."
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)

# 1e. Appending is idempotent: a second run replaces the region in place.
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
$after = [System.IO.File]::ReadAllText($claudeMd)
$beginCount = ([regex]::Matches($after, [regex]::Escape($beginMark))).Count
Check ($beginCount -eq 1)                                    'agents-md: block not appended twice'
Check ($after -match 'Run the linter before every commit\.') 'agents-md: developer content kept on re-run'
Check (-not (Test-Path "$claudeMd.bak1")) `
    'agents-md: up-to-date block inside a developer file made no new backup'

# 1f. Only the marked region is replaced; text above AND below survives, and no
#     backup is made because nothing outside our own region changed.
Remove-Item -LiteralPath $claudeMd -Force
Get-ChildItem -Path $proj -Filter 'CLAUDE.md.bak*' | Remove-Item -Force
[System.IO.File]::WriteAllText($claudeMd,
    "ABOVE-SENTINEL`n`n$beginMark`nstale block content`n$endMark`n`nBELOW-SENTINEL`n")
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
$after = [System.IO.File]::ReadAllText($claudeMd)
Check ($after -match 'ABOVE-SENTINEL')          'agents-md: text above the block kept'
Check ($after -match 'BELOW-SENTINEL')          'agents-md: text below the block kept'
Check (-not ($after -match 'stale block content')) 'agents-md: stale block content removed'
Check (-not (Test-Path "$claudeMd.bak"))        'agents-md: in-place replacement made no backup'

# 1g. A half-written marker is malformed: append, never truncate.
Remove-Item -LiteralPath $claudeMd -Force
Get-ChildItem -Path $proj -Filter 'CLAUDE.md.bak*' | Remove-Item -Force
[System.IO.File]::WriteAllText($claudeMd, "KEEP-ME`n$beginMark`nhalf a block`n")
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
$after = [System.IO.File]::ReadAllText($claudeMd)
Check ($after -match 'KEEP-ME')          'agents-md: malformed-marker file not truncated'
Check ($after -match 'half a block')     'agents-md: malformed-marker content kept'
Check ($after.Contains($endMark))        'agents-md: block appended to malformed file'

# A later run must pair the appended block with its own nearest BEGIN marker;
# the original orphan marker and the developer's content remain unmanaged.
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
$after = [System.IO.File]::ReadAllText($claudeMd)
Check ($after -match 'KEEP-ME')      'agents-md: malformed-marker file not truncated on re-run'
Check ($after -match 'half a block') 'agents-md: malformed-marker content kept on re-run'

# 1g2. Whole-line, nearest-pair semantics match install.sh. Standalone markers
#      in fenced examples and inline marker mentions are developer content.
Remove-Item -LiteralPath $claudeMd -Force
Get-ChildItem -Path $proj -Filter 'CLAUDE.md.bak*' | Remove-Item -Force
$fence = '```'
[System.IO.File]::WriteAllText($claudeMd,
    "# Project`n`n${fence}markdown`n$beginMark`n$fence`n`nTEAM-RULE-SENTINEL`n`n$beginMark`nstale block`n$endMark`n")
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
$after = [System.IO.File]::ReadAllText($claudeMd)
Check ($after -match 'TEAM-RULE-SENTINEL') 'agents-md: text after a fenced BEGIN marker kept'
Check ($after.Contains($fence))             'agents-md: fenced marker example not truncated'

Remove-Item -LiteralPath $claudeMd -Force
Get-ChildItem -Path $proj -Filter 'CLAUDE.md.bak*' | Remove-Item -Force
[System.IO.File]::WriteAllText($claudeMd,
    "# Project`n`nKeep the ``$beginMark`` and ``$endMark`` lines.`n")
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
$after = [System.IO.File]::ReadAllText($claudeMd)
Check ($after -match 'Keep the')                         'agents-md: inline marker prose kept'
Check ($after -match [regex]::Escape("and ``$endMark``")) 'agents-md: inline END marker prose kept'

# 1g3. Merging is byte-preserving. A legacy Windows-1252 byte in developer text
#      must not be decoded to U+FFFD while the UTF-8 block is updated.
Remove-Item -LiteralPath $claudeMd -Force
Get-ChildItem -Path $proj -Filter 'CLAUDE.md.bak*' | Remove-Item -Force
$prefixBytes = [byte[]](0x23,0x20,0x50,0x72,0x6f,0x6a,0x65,0x63,0x74,0x0a,0x0a,0x63,0x61,0x66,0xe9,0x0a,0x0a)
$staleBytes = [System.Text.Encoding]::ASCII.GetBytes("$beginMark`nstale block`n$endMark`n")
[System.IO.File]::WriteAllBytes($claudeMd, $prefixBytes + $staleBytes)
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
$afterBytes = [System.IO.File]::ReadAllBytes($claudeMd)
Check ($afterBytes[14] -eq 0xe9) 'agents-md: non-UTF-8 developer byte preserved'
Check (-not (($afterBytes | ForEach-Object { $_.ToString('X2') }) -join '').Contains('EFBFBD')) `
    'agents-md: invalid UTF-8 byte not replaced by U+FFFD'

# 1g4. A leading UTF-8 BOM and non-Latin-1 text survive an in-place update:
#      the file is spliced as bytes and never decoded (reading it as text
#      would drop the BOM and turn the Cyrillic into '?').
Remove-Item -LiteralPath $claudeMd -Force
Get-ChildItem -Path $proj -Filter 'CLAUDE.md.bak*' | Remove-Item -Force
$cyrillic = -join [char[]](0x041F, 0x0440, 0x043E, 0x0435, 0x043A, 0x0442)
[System.IO.File]::WriteAllText($claudeMd, "# $cyrillic`n`n$beginMark`nstale block`n$endMark`n",
    (New-Object System.Text.UTF8Encoding($true)))
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
$afterBytes = [System.IO.File]::ReadAllBytes($claudeMd)
$after = [System.Text.Encoding]::UTF8.GetString($afterBytes, 3, $afterBytes.Length - 3)
Check ($afterBytes[0] -eq 0xEF -and $afterBytes[1] -eq 0xBB -and $afterBytes[2] -eq 0xBF) `
    'agents-md: leading BOM kept on an in-place update'
Check ($after.StartsWith("# $cyrillic`n") -and -not $after.Contains('stale block') -and $after.Contains($endMark)) `
    'agents-md: non-Latin-1 developer text kept on an in-place update'

# 1h. A legacy full-file replaced correctly even with CRLF line endings -- a
#     regression guard keeping install.ps1 in step with install.sh's now-fixed
#     byte-exact marker/heading comparisons.
Remove-Item -LiteralPath $claudeMd -Force
Get-ChildItem -Path $proj -Filter 'CLAUDE.md.bak*' | Remove-Item -Force
[System.IO.File]::WriteAllText($claudeMd,
    "# Agent Instructions`r`n`r`nUse these instructions.`r`n`r`n## Skill routing`r`n`r`n- Persistent entity: create an entity`r`n")
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
Check (([System.IO.File]::ReadAllText($claudeMd)) -eq $blockText) `
    'agents-md: CRLF legacy guidelines replaced by the block'
Check ((Get-Content -Raw "$claudeMd.bak") -match 'Agent Instructions') `
    'agents-md: CRLF legacy guidelines backed up'

# 1i. A legacy file with a leading UTF-8 BOM is still recognised.
Remove-Item -LiteralPath $claudeMd -Force
Get-ChildItem -Path $proj -Filter 'CLAUDE.md.bak*' | Remove-Item -Force
$bomChar = [char]0xFEFF
[System.IO.File]::WriteAllText($claudeMd,
    "$bomChar# Coding Guidelines`n`nRead jmix-create-entity before adding an entity.`n",
    (New-Object System.Text.UTF8Encoding($false)))
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
Check (([System.IO.File]::ReadAllText($claudeMd)) -eq $blockText) `
    'agents-md: BOM legacy guidelines replaced by the block'
Check ((Get-Content -Raw "$claudeMd.bak") -match 'Coding Guidelines') `
    'agents-md: BOM legacy guidelines backed up'

# 1j. A developer file already holding the block, whole file CRLF: only the
#     marked region is replaced in place, no backup, and CRLF outside the
#     region survives untouched.
Remove-Item -LiteralPath $claudeMd -Force
Get-ChildItem -Path $proj -Filter 'CLAUDE.md.bak*' | Remove-Item -Force
[System.IO.File]::WriteAllText($claudeMd,
    "ABOVE-SENTINEL`r`n`r`n$beginMark`r`nstale block content`r`n$endMark`r`n`r`nBELOW-SENTINEL`r`n")
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
$after = [System.IO.File]::ReadAllText($claudeMd)
Check ($after.Contains("ABOVE-SENTINEL`r`n"))          'agents-md(CRLF): text above the block kept its CRLF ending'
Check ($after.Contains("BELOW-SENTINEL`r`n"))          'agents-md(CRLF): text below the block kept its CRLF ending'
Check (-not ($after.Contains('stale block content')))  'agents-md(CRLF): stale block content removed'
Check (-not (Test-Path "$claudeMd.bak"))               'agents-md(CRLF): in-place replacement made no backup'

# 1k. A third heading this toolkit actually shipped: "# Jmix Coding Guidelines".
Remove-Item -LiteralPath $claudeMd -Force
Get-ChildItem -Path $proj -Filter 'CLAUDE.md.bak*' | Remove-Item -Force
Set-Content -LiteralPath $claudeMd -NoNewline -Value @"
# Jmix Coding Guidelines

Use these instructions.

## Skill routing

- Persistent entity: create an entity
"@
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
Check (([System.IO.File]::ReadAllText($claudeMd)) -eq $blockText) `
    "agents-md: '# Jmix Coding Guidelines' legacy file replaced by the block"
Check ((Get-Content -Raw "$claudeMd.bak") -match 'Jmix Coding Guidelines') `
    "agents-md: '# Jmix Coding Guidelines' legacy file backed up"

# 1l. An early-vintage file: no "## Skill routing" heading at all, its only
#     toolkit signal is an old skill name ("jmix-services") that predates
#     jmix-create-entity.
Remove-Item -LiteralPath $claudeMd -Force
Get-ChildItem -Path $proj -Filter 'CLAUDE.md.bak*' | Remove-Item -Force
Set-Content -LiteralPath $claudeMd -NoNewline -Value @"
# Coding Guidelines

See jmix-services for the service layer conventions.
"@
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
Check (([System.IO.File]::ReadAllText($claudeMd)) -eq $blockText) `
    'agents-md: early-vintage file (jmix-services, no Skill routing) replaced'
Check ((Get-Content -Raw "$claudeMd.bak") -match 'jmix-services') `
    'agents-md: early-vintage file backed up'

# 1m. A no-trailing-newline destination file is appended to exactly like one
#     that already ends in a newline (guard, not a fix -- already byte-identical
#     across installers).
Remove-Item -LiteralPath $claudeMd -Force
Get-ChildItem -Path $proj -Filter 'CLAUDE.md.bak*' | Remove-Item -Force
[System.IO.File]::WriteAllText($claudeMd, "# My project`n`nRun the linter before every commit.")
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
$expected1m = "# My project`n`nRun the linter before every commit.`n`n" + $blockText
Check (([System.IO.File]::ReadAllText($claudeMd)) -eq $expected1m) `
    'agents-md: no-trailing-newline destination appended to byte-for-byte'
Check (Test-Path "$claudeMd.bak") 'agents-md: no-trailing-newline destination backed up'

function Reset-Guidelines {
    foreach ($f in @($claudeMd, $agentsMd, (Join-Path $proj 'AGENTS.override.md'))) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
    }
    Get-ChildItem -Path $proj -Filter 'CLAUDE.md.bak*' | Remove-Item -Force
    Get-ChildItem -Path $proj -Filter 'AGENTS.md.bak*' | Remove-Item -Force
    if (Test-Path -LiteralPath $junieDir) { Remove-Item -LiteralPath $junieDir -Recurse -Force }
}

# 1n. A CLAUDE.md that @-imports AGENTS.md (Claude Code import syntax) is left
#     alone when AGENTS.md carries the block: Claude sees it through the import,
#     a second copy would only duplicate it. No rewrite, no backup -- and the
#     AGENTS.md agents are processed first even though claude is listed first.
Reset-Guidelines
$importText = "# Team rules`n`nSee @AGENTS.md for the shared instructions.`n"
[System.IO.File]::WriteAllText($claudeMd, $importText)
[System.IO.File]::WriteAllText($agentsMd, "# Shared`n`nNever push to main.`n")
$null = Invoke-Installer @('agents-md', '-Agents', 'claude,codex', '-Source', $Source)
Check ((Get-Content -Raw $agentsMd) -match [regex]::Escape($beginMark)) 'agents-md: block merged into AGENTS.md'
Check ((Get-Content -Raw $agentsMd) -match 'Never push to main\.')     'agents-md: AGENTS.md content kept'
Check (([System.IO.File]::ReadAllText($claudeMd)) -eq $importText) `
    'agents-md: CLAUDE.md that imports AGENTS.md not rewritten'
Check (-not (Test-Path "$claudeMd.bak")) 'agents-md: CLAUDE.md that imports AGENTS.md not backed up'

# 1n2. Same import, only claude selected later: AGENTS.md still carries the block
#      from the earlier run, so CLAUDE.md is still skipped.
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
Check (([System.IO.File]::ReadAllText($claudeMd)) -eq $importText) `
    'agents-md: importing CLAUDE.md still skipped on a claude-only re-run'

# 1o. Same import, but AGENTS.md has no block and only claude is selected: nothing
#     else routes Claude to the skills, so the block goes into CLAUDE.md and
#     AGENTS.md is not touched.
Reset-Guidelines
[System.IO.File]::WriteAllText($claudeMd, $importText)
[System.IO.File]::WriteAllText($agentsMd, "# Shared`n`nNever push to main.`n")
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
Check ((Get-Content -Raw $claudeMd) -match [regex]::Escape($beginMark)) `
    'agents-md: block added to importing CLAUDE.md when AGENTS.md is unmanaged'
Check ((Get-Content -Raw $claudeMd) -match 'See @AGENTS\.md') 'agents-md: import line kept'
Check (-not ((Get-Content -Raw $agentsMd) -match [regex]::Escape($beginMark))) `
    'agents-md: AGENTS.md untouched when only claude selected'

# 1p. CLAUDE.md symlinked to AGENTS.md (a common setup). Claude-only: the block is
#     written through the link, which survives, and AGENTS.md gets it once. Both
#     agents: the shared file is still touched once. Needs symlink privilege.
if (Test-SymlinkCapable) {
    Reset-Guidelines
    [System.IO.File]::WriteAllText($agentsMd, "# Shared`n`nNever push to main.`n")
    New-Item -ItemType SymbolicLink -Path $claudeMd -Target 'AGENTS.md' | Out-Null
    $null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
    Check ((Get-Item -LiteralPath $claudeMd -Force).LinkType -eq 'SymbolicLink') `
        'agents-md: symlinked CLAUDE.md survives'
    Check (([regex]::Matches((Get-Content -Raw $agentsMd), [regex]::Escape($beginMark))).Count -eq 1) `
        'agents-md: block written once through the CLAUDE.md symlink'
    Check ((Get-Content -Raw $agentsMd) -match 'Never push to main\.') 'agents-md: linked AGENTS.md content kept'
    $null = Invoke-Installer @('agents-md', '-Agents', 'claude,codex', '-Source', $Source)
    Check ((Get-Item -LiteralPath $claudeMd -Force).LinkType -eq 'SymbolicLink') `
        'agents-md: symlinked CLAUDE.md survives a re-run'
    Check (([regex]::Matches((Get-Content -Raw $agentsMd), [regex]::Escape($beginMark))).Count -eq 1) `
        'agents-md: block not duplicated through the CLAUDE.md symlink'
} else {
    Write-Host 'skip: no symlink privilege, skipping the CLAUDE.md -> AGENTS.md symlink case'
}

# 1q. A developer file with a legacy heading that mentions jmix-* things which are
#     not toolkit skills (jmix-flowui, a jmix-framework URL) is NOT legacy: append.
Reset-Guidelines
[System.IO.File]::WriteAllText($claudeMd, "# Coding Guidelines`n`nWe use jmix-flowui; see https://github.com/jmix-framework/jmix.`n")
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
Check ((Get-Content -Raw $claudeMd) -match 'We use jmix-flowui') `
    'agents-md: jmix-flowui / jmix-framework mentions are not a legacy signal'
Check ((Get-Content -Raw $claudeMd) -match [regex]::Escape($beginMark)) 'agents-md: block appended to jmix-flowui file'

# Backups are first-class changes in the Studio summary, not only log text.
Reset-Guidelines
[System.IO.File]::WriteAllText($claudeMd, "# Team rules`n`nKeep this.`n")
$env:JMIX_EMIT_CHANGE_MARKERS = '1'
$markerOutput = Invoke-InstallerCapture @('agents-md', '-Agents', 'claude', '-Source', $Source)
Remove-Item Env:JMIX_EMIT_CHANGE_MARKERS
Check ($markerOutput -match '@@JMIX_CHANGE@@\s+action=backed-up\s+type=file\s+path=') `
    'agents-md: backup emitted as a Studio change marker'

# 1r. The earliest "# Coding Guidelines" vintage, trimmed down to its "## Skills
#     and MCP" section with no skill name left: still recognised as legacy.
Reset-Guidelines
[System.IO.File]::WriteAllText($claudeMd, "# Coding Guidelines`n`nThis file provides guidance to AI coding agents.`n`n## Skills and MCP`n`n- ALWAYS use the Skill tool.`n")
$null = Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)
Check (([System.IO.File]::ReadAllText($claudeMd)) -eq $blockText) `
    "agents-md: early-vintage file recognised by its 'Skills and MCP' section"

# 1s. A destination that exists but is not a file is an error, not a merge.
Reset-Guidelines
New-Item -ItemType Directory -Path $claudeMd | Out-Null
Check ((Invoke-Installer @('agents-md', '-Agents', 'claude', '-Source', $Source)) -ne 0) `
    'agents-md: a directory named CLAUDE.md fails'
Remove-Item -LiteralPath $claudeMd -Force

# 1t. Codex reads only the first 32 KiB of AGENTS.md, so an unmarked AGENTS.md
#     gets the block on top; a leading BOM stays first. Other files (CLAUDE.md,
#     see 1d) still get it at the end.
Reset-Guidelines
$bomBytes = [byte[]](0xEF, 0xBB, 0xBF)
$sharedText = "# Shared`n`nNever push to main.`n"
[System.IO.File]::WriteAllBytes($agentsMd, $bomBytes + [System.Text.Encoding]::UTF8.GetBytes($sharedText))
$null = Invoke-Installer @('agents-md', '-Agents', 'codex', '-Source', $Source)
$afterBytes = [System.IO.File]::ReadAllBytes($agentsMd)
Check ($afterBytes[0] -eq 0xEF -and $afterBytes[1] -eq 0xBB -and $afterBytes[2] -eq 0xBF) `
    'agents-md: AGENTS.md kept its leading BOM'
$afterText = [System.Text.Encoding]::UTF8.GetString($afterBytes, 3, $afterBytes.Length - 3)
Check ($afterText -ceq ($blockText + "`n" + $sharedText)) `
    'agents-md: the block is on top of an unmarked AGENTS.md, developer content below it'
Check (Test-Path "$agentsMd.bak") 'agents-md: AGENTS.md backed up'
Check (-not (Test-Path $claudeMd)) 'agents-md: -Agents codex leaves CLAUDE.md alone'

# 1u. Codex: a block past 32 KiB and an AGENTS.override.md are reported.
Reset-Guidelines
$rules = (0..699 | ForEach-Object { "Rule ${_}: keep the build green and the tests fast." }) -join "`n"
[System.IO.File]::WriteAllText($agentsMd, "$rules`n$blockText")
[System.IO.File]::WriteAllText((Join-Path $proj 'AGENTS.override.md'), "local rules`n")
$out = Invoke-InstallerCapture @('agents-md', '-Agents', 'codex', '-Source', $Source)
Check ($out -match 'first 32 KiB')        "agents-md: warns about a block past Codex's 32 KiB"
Check ($out -match 'AGENTS\.override\.md') 'agents-md: warns about AGENTS.override.md'

# 1v. Junie follows the shared convention: its block goes into the root
#     AGENTS.md like codex/opencode, and .junie/AGENTS.md / .junie/guidelines.md
#     are not touched.
Reset-Guidelines
New-Item -ItemType Directory -Path $junieDir | Out-Null
$junieAgents = Join-Path $junieDir 'AGENTS.md'
$legacyJunie = Join-Path $junieDir 'guidelines.md'
[System.IO.File]::WriteAllText($junieAgents, "# Junie rules`n")
[System.IO.File]::WriteAllText($legacyJunie, "# Old Junie rules`n")
$null = Invoke-Installer @('agents-md', '-Agents', 'opencode,junie', '-Source', $Source)
Check ((Test-Path $agentsMd) -and ([System.IO.File]::ReadAllText($agentsMd) -eq $blockText) -and -not (Test-Path $claudeMd)) `
    "agents-md: Junie's block written to the root AGENTS.md alone"
Check (([System.IO.File]::ReadAllText($junieAgents) -eq "# Junie rules`n") -and
       ([System.IO.File]::ReadAllText($legacyJunie) -eq "# Old Junie rules`n")) `
    'agents-md: .junie guidelines files untouched'

# 1za. A NUL byte in AGENTS.md does not stop the agents after codex.
Reset-Guidelines
[System.IO.File]::WriteAllBytes($agentsMd, [byte[]](0x23, 0x20, 0x52, 0x0a, 0x78, 0x00, 0x79, 0x0a))
Check ((Invoke-Installer @('agents-md', '-Agents', 'codex,claude', '-Source', $Source)) -eq 0 -and (Test-Path $claudeMd)) `
    'agents-md: a NUL byte in AGENTS.md does not stop the agents after codex'

# Reset so later sections start from a clean project guidelines state.
Reset-Guidelines

# ---------------------------------------------------------------------------
# 2. skills, local scope -- must succeed without symlink privilege
#    (junction on Windows / symlink on Unix), so the assertions run unconditionally.
#    The skills are kept in the project's .agents/skills (the store) and linked
#    into .claude/skills; an old .skills store is migrated away.
# ---------------------------------------------------------------------------
$linkType = if (Test-SymlinkCapable) { 'SymbolicLink' } elseif ($onWindows) { 'Junction' } else { $null }
$skillNames = @(Get-ChildItem -LiteralPath (Join-Path $Source 'content/skills') -Directory | ForEach-Object { $_.Name })

# True when $Path is a real folder, not a link (or junction) to one.
function Test-RealDir {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return ($null -ne $item -and $item.PSIsContainer -and -not $item.LinkType)
}

# True when $Link is a link into a project's .agents/skills that resolves.
function Test-LinkIntoStore {
    param([string]$Link)
    $item = Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or -not $item.LinkType) { return $false }
    $target = [string](@($item.Target) | Select-Object -First 1)
    return ($target -match '[\\/]\.agents[\\/]skills[\\/][^\\/]+$' -and (Test-Path -LiteralPath (Join-Path $Link 'SKILL.md')))
}

# What the old layout could leave in the agent skills dirs of project $Dir:
# links into .skills and *.bak* entries. Returns their paths.
function Get-LegacyLeftovers {
    param([string]$Dir)
    foreach ($rel in '.agents/skills', '.claude/skills') {
        $agentDir = Join-Path $Dir $rel
        if (-not (Test-Path -LiteralPath $agentDir -PathType Container)) { continue }
        foreach ($item in Get-ChildItem -LiteralPath $agentDir -Force) {
            $target = [string](@($item.Target) | Select-Object -First 1)
            if ($item.Name -like '*.bak*' -or ($item.LinkType -and $target -match '[\\/]\.skills([\\/]|$)')) { $item.FullName }
        }
    }
}

# The entries of project $Dir's agent skills dirs: path, link type and target.
function Get-SkillsLayout {
    param([string]$Dir)
    foreach ($rel in '.agents/skills', '.claude/skills') {
        Get-ChildItem -LiteralPath (Join-Path $Dir $rel) -Force -ErrorAction SilentlyContinue |
            ForEach-Object { "$rel/$($_.Name)|$($_.LinkType)|$(@($_.Target) -join ',')" }
    }
}

function New-TestProject {
    param([string]$Name)
    $dir = Join-Path $work $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

# Runs a local skills install in project $Dir with the extra arguments $More.
function Invoke-LocalSkills {
    param([string]$Dir, [string[]]$More)
    Push-Location $Dir
    try { return Invoke-InstallerResult (@('skills', '-Scope', 'local', '-Source', $Source) + $More) }
    finally { Pop-Location }
}

# Lays project $Dir out as earlier versions installed it: the skills in .skills,
# with a retired skill and a store backup beside them, each linked into the
# agent skills dirs $AgentDirs with an absolute target, as the old installer did.
function New-LegacyLayout {
    param([string]$Dir, [string[]]$AgentDirs = @('.agents/skills', '.claude/skills'))
    $legacy = Join-Path $Dir '.skills'
    New-Item -ItemType Directory -Force -Path $legacy | Out-Null
    Copy-Item -Path (Join-Path $Source 'content/skills/*') -Destination $legacy -Recurse
    foreach ($n in 'jmix-obsolete-skill', "$skill.bak") {
        New-Item -ItemType Directory -Force -Path (Join-Path $legacy $n) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $legacy "$n/SKILL.md"), "# $n`n")
    }
    foreach ($rel in $AgentDirs) {
        $agentDir = Join-Path $Dir $rel
        New-Item -ItemType Directory -Force -Path $agentDir | Out-Null
        foreach ($s in Get-ChildItem -LiteralPath $legacy -Directory) {
            New-Item -ItemType $linkType -Path (Join-Path $agentDir $s.Name) -Target $s.FullName | Out-Null
        }
    }
}

Check ((Invoke-Installer @('skills', '-Agents', 'claude,codex,opencode,junie', '-Scope', 'local', '-Source', $Source)) -eq 0) `
    'skills(local) exits 0'
Check ((Test-RealDir (Join-Path $proj ".agents/skills/$skill")) -and (Test-Path (Join-Path $proj ".agents/skills/$skill/SKILL.md"))) `
    'skills(local): the skill is a real folder in .agents/skills (the store)'
Check (Test-LinkIntoStore (Join-Path $proj ".claude/skills/$skill")) 'skills(local): .claude/skills links the skill into .agents/skills'
Check (-not (Test-Path (Join-Path $proj '.skills')))                 'skills(local): no .skills store'
Check (-not (Test-Path (Join-Path $proj '.junie/skills')))         'skills(local): no .junie/skills; Junie reads .agents/skills'

# Studio reads the local store from the manifest: it must be the dir used here.
$manifest = Get-Content -Raw -LiteralPath (Join-Path $Source '.studio/skills-manifest.json') | ConvertFrom-Json
Check ($manifest.store.local -eq '.agents/skills' -and (Test-RealDir (Join-Path $proj "$($manifest.store.local)/$skill"))) `
    'skills(local): the Studio manifest names the store the installer uses'

# Claude alone still keeps the skills in .agents/skills; agents alone makes no .claude.
$convProj = New-TestProject 'conventions-claude-project'
$r = Invoke-LocalSkills -Dir $convProj -More @('-Conventions', 'claude')
Check ($r.Code -eq 0 -and (Test-RealDir (Join-Path $convProj ".agents/skills/$skill")) -and
       (Test-LinkIntoStore (Join-Path $convProj ".claude/skills/$skill"))) `
    'skills: -Conventions claude keeps the skills in .agents/skills and links them into .claude/skills'
$convProj = New-TestProject 'conventions-agents-project'
$r = Invoke-LocalSkills -Dir $convProj -More @('-Conventions', 'agents')
Check ($r.Code -eq 0 -and (Test-Path (Join-Path $convProj ".agents/skills/$skill/SKILL.md")) -and
       -not (Test-Path (Join-Path $convProj '.claude'))) 'skills: -Conventions agents installs .agents/skills alone'

# The user's own skills in both dirs survive an install and a re-install, and
# a re-run leaves the same layout.
$ownProj = New-TestProject 'own-skills-project'
foreach ($rel in '.agents/skills/my-skill', '.claude/skills/my-skill') {
    New-Item -ItemType Directory -Force -Path (Join-Path $ownProj $rel) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $ownProj "$rel/SKILL.md"), "# mine`n")
}
$layouts = @{}
foreach ($run in 1, 2) {
    $r = Invoke-LocalSkills -Dir $ownProj -More @('-Conventions', 'agents,claude')
    Check ($r.Code -eq 0) "skills(local): run $run exits 0"
    Check ((Test-Path (Join-Path $ownProj '.agents/skills/my-skill/SKILL.md')) -and
           (Test-Path (Join-Path $ownProj '.claude/skills/my-skill/SKILL.md'))) "skills(local): the user's own skills kept (run $run)"
    Check ((Test-RealDir (Join-Path $ownProj ".agents/skills/$skill")) -and (Test-LinkIntoStore (Join-Path $ownProj ".claude/skills/$skill")) -and
           @(Get-LegacyLeftovers $ownProj).Count -eq 0 -and -not (Test-Path (Join-Path $ownProj '.skills'))) `
        "skills(local): the new layout after run $run"
    $layouts[$run] = @(Get-SkillsLayout $ownProj) -join "`n"
}
Check ($layouts[1] -ne '' -and $layouts[2] -eq $layouts[1]) 'skills(local): a re-run leaves the same layout'

# Links an earlier version put into .junie/skills are removed (Junie's CLI reads
# that dir first, so they would shadow newer skills); other skills stay.
$oldJunieSkills = Join-Path $proj '.junie/skills'
New-Item -ItemType Directory -Force -Path (Join-Path $oldJunieSkills 'my-skill') | Out-Null
if ($linkType) {
    foreach ($n in 'jmix', $skill) {
        # The old store they point into; the run migrates it away.
        New-Item -ItemType Directory -Force -Path (Join-Path $proj ".skills/$n") | Out-Null
        New-Item -ItemType $linkType -Path (Join-Path $oldJunieSkills $n) -Target (Join-Path $proj ".skills/$n") | Out-Null
    }
    $out = Invoke-InstallerCapture @('skills', '-Agents', 'codex', '-Scope', 'local', '-Source', $Source)
    Check (-not (Test-Path -LiteralPath (Join-Path $oldJunieSkills 'jmix')) -and
           -not (Get-Item -LiteralPath (Join-Path $oldJunieSkills $skill) -Force -ErrorAction SilentlyContinue)) `
        'skills(local): old toolkit links in .junie/skills removed'
    Check (Test-Path (Join-Path $oldJunieSkills 'my-skill')) 'skills(local): foreign skill in .junie/skills kept'
    Check (Test-Path (Join-Path $proj ".agents/skills/$skill/SKILL.md")) 'skills(local): removing old links kept the store'
    Check ($out -match 'Removed old Junie skill link') 'skills(local): removal of old Junie links reported'
} else {
    Write-Host 'skip: no link support, skipping the old .junie/skills links case'
}
Remove-Item -LiteralPath (Join-Path $proj '.junie') -Recurse -Force

if ($linkType) {
    # At local scope .agents/skills is the store, so Junie keeps its skills after
    # a Claude-only run too: the links go, or they would dangle once .skills does.
    New-Item -ItemType Directory -Force -Path $oldJunieSkills, (Join-Path $proj ".skills/$skill") | Out-Null
    $oldLink = Join-Path $oldJunieSkills $skill
    New-Item -ItemType $linkType -Path $oldLink -Target (Join-Path $proj ".skills/$skill") | Out-Null
    $null = Invoke-Installer @('skills', '-Agents', 'claude', '-Scope', 'local', '-Source', $Source)
    Check (-not (Get-Item -LiteralPath $oldLink -Force -ErrorAction SilentlyContinue)) `
        'skills(local): old Junie links removed by a Claude-only run'
    if (Test-Path -LiteralPath $junieDir) { Remove-Item -LiteralPath $junieDir -Recurse -Force }

    # A .junie/skills that is the same dir as an agent skills dir holds the links
    # this run just created: the cleanup leaves it alone.
    New-Item -ItemType Directory -Force -Path $junieDir | Out-Null
    New-Item -ItemType $linkType -Path $oldJunieSkills -Target (Join-Path $proj '.agents/skills') | Out-Null
    $out = Invoke-InstallerCapture @('skills', '-Agents', 'codex,junie', '-Scope', 'local', '-Source', $Source)
    Check (Test-Path (Join-Path $proj ".agents/skills/$skill/SKILL.md")) `
        'skills(local): links kept through a .junie/skills -> .agents/skills link'
    Check ($out -notmatch 'Removed old Junie skill link') 'skills(local): nothing removed from a shared .junie/skills'
    if (Get-Item -LiteralPath $oldJunieSkills -Force -ErrorAction SilentlyContinue) {
        [System.IO.Directory]::Delete($oldJunieSkills, $false)
    }
    Remove-Item -LiteralPath $junieDir -Recurse -Force

    # .claude/skills linked to the old store, which also holds a skill of the
    # user's: that dir is the user's own, so it stays, and the skills are linked
    # into it. A store an earlier version turned into self-links is repaired.
    $selfProj = New-TestProject 'self-link-project'
    New-Item -ItemType Directory -Force -Path (Join-Path $selfProj '.claude'), (Join-Path $selfProj '.skills/my-skill') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $selfProj '.skills/my-skill/SKILL.md'), "# mine`n")
    New-Item -ItemType $linkType -Path (Join-Path $selfProj '.claude/skills') -Target (Join-Path $selfProj '.skills') | Out-Null
    if ($linkType -eq 'SymbolicLink') {
        New-Item -ItemType SymbolicLink -Path (Join-Path $selfProj ".skills/$skill") -Target "./$skill" | Out-Null
    }
    $runs = @(1, 2 | ForEach-Object { Invoke-LocalSkills -Dir $selfProj -More @('-Conventions', 'claude') })
    Check (@($runs | Where-Object { $_.Code -ne 0 }).Count -eq 0) 'skills(local): runs succeed with .claude/skills linked to .skills'
    Check (Test-Path (Join-Path $selfProj '.skills/my-skill/SKILL.md')) "skills(local): the user's skill in a linked .skills kept"
    Check (Test-Path (Join-Path $selfProj ".claude/skills/$skill/SKILL.md")) 'skills(local): the skill resolves through .claude/skills -> .skills'
    Check (Test-RealDir (Join-Path $selfProj ".agents/skills/$skill")) 'skills(local): the store is .agents/skills next to a linked .skills'

    # An agent skills dir that is the store itself already has the skills; linking
    # them into it would replace every skill with a link to itself.
    $storeLinkProj = New-TestProject 'store-link-project'
    New-Item -ItemType Directory -Force -Path (Join-Path $storeLinkProj '.agents'), (Join-Path $storeLinkProj '.claude/skills') | Out-Null
    New-Item -ItemType $linkType -Path (Join-Path $storeLinkProj '.agents/skills') -Target (Join-Path $storeLinkProj '.claude/skills') | Out-Null
    $runs = @(1, 2 | ForEach-Object { Invoke-LocalSkills -Dir $storeLinkProj -More @('-Conventions', 'claude') })
    Check (@($runs | Where-Object { $_.Code -ne 0 }).Count -eq 0) 'skills(local): runs succeed with .agents/skills linked to .claude/skills'
    Check ($runs[1].Output -match 'is the skills store itself' -and $runs[1].Output -notmatch 'Linked skills into') `
        'skills(local): reports that .claude/skills is the store instead of linking'
    Check ((Test-RealDir (Join-Path $storeLinkProj ".claude/skills/$skill")) -and (Test-Path (Join-Path $storeLinkProj ".claude/skills/$skill/SKILL.md"))) `
        'skills(local): store kept when .claude/skills is the store'

    # The old layout: skills in .skills, linked into both agent dirs.
    $legacyProj = New-TestProject 'legacy-project'
    New-LegacyLayout -Dir $legacyProj
    $r = Invoke-LocalSkills -Dir $legacyProj -More @('-Conventions', 'agents,claude')
    Check ($r.Code -eq 0) 'skills(local): migrating the old .skills layout exits 0'
    Check (@($skillNames | Where-Object { -not (Test-RealDir (Join-Path $legacyProj ".agents/skills/$_")) }).Count -eq 0) `
        'skills(local): migrated skills are real folders in .agents/skills'
    Check (@($skillNames | Where-Object { -not (Test-LinkIntoStore (Join-Path $legacyProj ".claude/skills/$_")) }).Count -eq 0) `
        'skills(local): migrated .claude/skills links into .agents/skills'
    Check (@(Get-LegacyLeftovers $legacyProj).Count -eq 0) 'skills(local): no links into .skills and no backups left in the agent dirs'
    Check (-not (Test-Path (Join-Path $legacyProj '.skills'))) 'skills(local): the old .skills store removed'
    Check ($r.Output -match 'Removed the old skills store') 'skills(local): removal of the old store reported'
    # A jmix* entry that is no toolkit skill may be the user's own: it is kept
    # out of the agent dirs, in the backups; the toolkit's are only deleted.
    $backups = Join-Path $legacyProj '.agents/.jmix/backups'
    Check ((@(Get-ChildItem -LiteralPath $backups -Force -ErrorAction SilentlyContinue).Name -join ',') -eq 'jmix-obsolete-skill.bak' -and
           (Test-Path (Join-Path $backups 'jmix-obsolete-skill.bak/SKILL.md'))) `
        'skills(local): without -BackupExistingFiles only an unknown jmix skill is backed up'

    # Files of the user's in .skills keep it, and only them; the jmix name test
    # is case-sensitive, as in install.sh.
    $keepProj = New-TestProject 'legacy-keep-project'
    New-LegacyLayout -Dir $keepProj
    [System.IO.File]::WriteAllText((Join-Path $keepProj '.skills/notes.txt'), "mine`n")
    [System.IO.File]::WriteAllText((Join-Path $keepProj '.skills/JMIX-README.md'), "mine`n")
    $r = Invoke-LocalSkills -Dir $keepProj -More @('-Conventions', 'agents,claude')
    Check ($r.Code -eq 0 -and (@(Get-ChildItem -LiteralPath (Join-Path $keepProj '.skills') -Force -ErrorAction SilentlyContinue |
            Sort-Object Name).Name -join ',') -eq 'JMIX-README.md,notes.txt') `
        'skills(local): a .skills holding other files keeps only them'

    # A .skills that is a link is the user's own arrangement: left alone.
    $sharedProj = New-TestProject 'legacy-linked-project'
    $shared = Join-Path $work 'shared-skills'
    New-Item -ItemType Directory -Force -Path (Join-Path $shared 'jmix-foo') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $shared 'jmix-foo/SKILL.md'), "# foo`n")
    New-Item -ItemType $linkType -Path (Join-Path $sharedProj '.skills') -Target $shared | Out-Null
    $r = Invoke-LocalSkills -Dir $sharedProj -More @('-Conventions', 'agents,claude')
    Check ($r.Code -eq 0 -and (Test-Path (Join-Path $shared 'jmix-foo/SKILL.md')) -and
           [bool](Get-Item -LiteralPath (Join-Path $sharedProj '.skills') -Force).LinkType) `
        'skills(local): a .skills that is a link is left alone'

    # Other agents' skills dirs linked into .skills keep working: per-skill links
    # are re-linked into the store, and a whole-dir link keeps .skills as it is.
    $otherProj = New-TestProject 'legacy-cursor-project'
    New-LegacyLayout -Dir $otherProj -AgentDirs @('.claude/skills', '.cursor/skills')
    $r = Invoke-LocalSkills -Dir $otherProj -More @('-Conventions', 'agents,claude')
    Check ($r.Code -eq 0 -and @($skillNames | Where-Object { -not (Test-LinkIntoStore (Join-Path $otherProj ".cursor/skills/$_")) }).Count -eq 0 -and
           -not (Get-Item -LiteralPath (Join-Path $otherProj '.cursor/skills/jmix-obsolete-skill') -Force -ErrorAction SilentlyContinue) -and
           -not (Test-Path (Join-Path $otherProj '.skills'))) `
        "skills(local): another agent's links into .skills are re-linked into the store"
    # That .skills gets the skills linked in like .claude/skills, so it does not
    # go stale, also when that agent's convention is not chosen.
    $otherProj = New-TestProject 'legacy-github-project'
    New-LegacyLayout -Dir $otherProj -AgentDirs @('.agents/skills')
    New-Item -ItemType Directory -Force -Path (Join-Path $otherProj '.github') | Out-Null
    New-Item -ItemType $linkType -Path (Join-Path $otherProj '.github/skills') -Target (Join-Path $otherProj '.skills') | Out-Null
    $r = Invoke-LocalSkills -Dir $otherProj -More @('-Conventions', 'agents')
    Check ($r.Code -eq 0 -and (Test-Path (Join-Path $otherProj ".github/skills/$skill/SKILL.md")) -and
           (Test-LinkIntoStore (Join-Path $otherProj ".skills/$skill")) -and
           (Test-Path (Join-Path $otherProj '.github/skills/jmix-obsolete-skill/SKILL.md'))) `
        "skills(local): .skills kept when another agent's skills dir links to it, and linked to the store"

    # Finder clutter does not keep .skills, and a real backup an older version
    # made beside a skill in .claude/skills moves to .agents/.jmix/backups.
    $clutterProj = New-TestProject 'legacy-clutter-project'
    New-LegacyLayout -Dir $clutterProj
    [System.IO.File]::WriteAllText((Join-Path $clutterProj '.skills/.DS_Store'), '')
    Copy-Item -Path (Join-Path $Source "content/skills/$skill") -Destination (Join-Path $clutterProj ".claude/skills/$skill.bak1") -Recurse
    $r = Invoke-LocalSkills -Dir $clutterProj -More @('-Conventions', 'agents,claude')
    Check ($r.Code -eq 0 -and -not (Test-Path (Join-Path $clutterProj '.skills')) -and @(Get-LegacyLeftovers $clutterProj).Count -eq 0 -and
           (Test-Path (Join-Path $clutterProj ".agents/.jmix/backups/$skill.bak1.bak/SKILL.md"))) `
        'skills(local): Finder clutter and real old backups do not stay behind'

    # Agents alone: .claude/skills is still re-linked away from .skills.
    $legacyProj = New-TestProject 'legacy-agents-project'
    New-LegacyLayout -Dir $legacyProj
    $r = Invoke-LocalSkills -Dir $legacyProj -More @('-Conventions', 'agents')
    Check ($r.Code -eq 0 -and (Test-LinkIntoStore (Join-Path $legacyProj ".claude/skills/$skill")) -and
           @(Get-LegacyLeftovers $legacyProj).Count -eq 0 -and -not (Test-Path (Join-Path $legacyProj '.skills'))) `
        'skills(local): -Conventions agents re-links the old .claude/skills into .agents/skills'

    # An old Claude-only layout: .skills linked into .claude/skills alone.
    $legacyProj = New-TestProject 'legacy-claude-project'
    New-LegacyLayout -Dir $legacyProj -AgentDirs @('.claude/skills')
    $r = Invoke-LocalSkills -Dir $legacyProj -More @('-Conventions', 'claude')
    Check ($r.Code -eq 0 -and (Test-RealDir (Join-Path $legacyProj ".agents/skills/$skill")) -and
           (Test-LinkIntoStore (Join-Path $legacyProj ".claude/skills/$skill")) -and
           @(Get-LegacyLeftovers $legacyProj).Count -eq 0 -and -not (Test-Path (Join-Path $legacyProj '.skills'))) `
        'skills(local): an old Claude-only layout is migrated'

    # .agents/skills linked to .skills by the user: .skills is the store then,
    # and nothing in it is removed.
    $userLinkProj = New-TestProject 'agents-link-project'
    New-Item -ItemType Directory -Force -Path (Join-Path $userLinkProj '.skills'), (Join-Path $userLinkProj '.agents') | Out-Null
    Copy-Item -Path (Join-Path $Source 'content/skills/*') -Destination (Join-Path $userLinkProj '.skills') -Recurse
    New-Item -ItemType $linkType -Path (Join-Path $userLinkProj '.agents/skills') -Target (Join-Path $userLinkProj '.skills') | Out-Null
    $r = Invoke-LocalSkills -Dir $userLinkProj -More @('-Conventions', 'agents,claude')
    Check ($r.Code -eq 0 -and (Test-RealDir (Join-Path $userLinkProj ".skills/$skill")) -and
           (Test-Path (Join-Path $userLinkProj ".skills/$skill/SKILL.md")) -and
           (Test-Path (Join-Path $userLinkProj ".claude/skills/$skill/SKILL.md"))) `
        'skills(local): a .agents/skills -> .skills link of the user is kept as the store'

    # A dangling .agents/skills is replaced by the store.
    $danglingProj = New-TestProject 'dangling-store-project'
    New-Item -ItemType Directory -Force -Path (Join-Path $danglingProj 'missing'), (Join-Path $danglingProj '.agents') | Out-Null
    New-Item -ItemType $linkType -Path (Join-Path $danglingProj '.agents/skills') -Target (Join-Path $danglingProj 'missing') | Out-Null
    Remove-Item -LiteralPath (Join-Path $danglingProj 'missing') -Recurse -Force
    $r = Invoke-LocalSkills -Dir $danglingProj -More @('-Conventions', 'agents,claude')
    Check ($r.Code -eq 0 -and (Test-RealDir (Join-Path $danglingProj ".agents/skills/$skill"))) `
        'skills(local): a dangling .agents/skills link is replaced by the store'

    # A dangling per-skill link into a .skills that is gone is re-linked.
    foreach ($conv in 'agents,claude', 'agents') {
        $danglingProj = New-TestProject "dangling-link-$($conv -replace ',', '-')-project"
        New-Item -ItemType Directory -Force -Path (Join-Path $danglingProj ".skills/$skill"), (Join-Path $danglingProj '.claude/skills') | Out-Null
        New-Item -ItemType $linkType -Path (Join-Path $danglingProj ".claude/skills/$skill") -Target (Join-Path $danglingProj ".skills/$skill") | Out-Null
        Remove-Item -LiteralPath (Join-Path $danglingProj '.skills') -Recurse -Force
        $r = Invoke-LocalSkills -Dir $danglingProj -More @('-Conventions', $conv)
        Check ($r.Code -eq 0 -and (Test-LinkIntoStore (Join-Path $danglingProj ".claude/skills/$skill"))) `
            "skills(local): a dangling .claude/skills link is re-linked into the store ($conv)"
    }

    # -BackupExistingFiles: replaced skill folders go to .agents/.jmix/backups,
    # never into the dirs the agents scan, and a link is never backed up.
    $backupProj = New-TestProject 'backup-project'
    $backups = Join-Path $backupProj '.agents/.jmix/backups'
    $r = Invoke-LocalSkills -Dir $backupProj -More @('-Conventions', 'agents,claude', '-BackupExistingFiles')
    Check ($r.Code -eq 0 -and -not (Test-Path $backups)) 'skills(local): a fresh install makes no backups dir'
    $r = Invoke-LocalSkills -Dir $backupProj -More @('-Conventions', 'agents,claude', '-BackupExistingFiles')
    Check ($r.Code -eq 0 -and @(Get-LegacyLeftovers $backupProj).Count -eq 0) 'skills(local): no backups in the agent dirs'
    Check ((Test-RealDir (Join-Path $backups "$skill.bak")) -and (Test-Path (Join-Path $backups "$skill.bak/SKILL.md"))) `
        'skills(local): the replaced skill backed up into .agents/.jmix/backups'
    $backupProj = New-TestProject 'backup-legacy-project'
    $backups = Join-Path $backupProj '.agents/.jmix/backups'
    New-LegacyLayout -Dir $backupProj
    $r = Invoke-LocalSkills -Dir $backupProj -More @('-Conventions', 'agents,claude', '-BackupExistingFiles')
    Check ($r.Code -eq 0 -and @(Get-LegacyLeftovers $backupProj).Count -eq 0 -and -not (Test-Path (Join-Path $backupProj '.skills'))) `
        'skills(local): the old layout migrated with -BackupExistingFiles'
    Check ((Test-Path (Join-Path $backups "$skill.bak/SKILL.md")) -and (Test-Path (Join-Path $backups 'jmix-obsolete-skill.bak/SKILL.md'))) `
        'skills(local): the old store backed up into .agents/.jmix/backups'
    Check (-not (Test-Path (Join-Path $backups "$skill.bak1")) -and
           @(Get-ChildItem -LiteralPath $backups -Force -ErrorAction SilentlyContinue | Where-Object { $_.LinkType }).Count -eq 0) `
        'skills(local): no links backed up'

    # A real copy of a skill in .claude/skills is backed up out of it and linked.
    $copyProj = New-TestProject 'claude-copy-project'
    New-Item -ItemType Directory -Force -Path (Join-Path $copyProj ".claude/skills/$skill") | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $copyProj ".claude/skills/$skill/SKILL.md"), "# my copy`n")
    $r = Invoke-LocalSkills -Dir $copyProj -More @('-Conventions', 'claude', '-BackupExistingFiles')
    Check ($r.Code -eq 0 -and (Test-LinkIntoStore (Join-Path $copyProj ".claude/skills/$skill")) -and
           @(Get-LegacyLeftovers $copyProj).Count -eq 0) 'skills(local): a real skill copy in .claude/skills is replaced by a link'
    Check ((Get-Content -Raw -LiteralPath (Join-Path $copyProj ".agents/.jmix/backups/$skill.bak/SKILL.md")) -match 'my copy') `
        'skills(local): the real skill copy backed up into .agents/.jmix/backups'
}

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
Check (Test-LinkIntoStore (Join-Path $proj ".claude/skills/$skill")) 'skills(local): claude link still resolves after re-run'

# skills global -- store keyed by the branch (CONTENT_REF)
Check ((Invoke-Installer @('skills', '-Agents', 'claude', '-Scope', 'global', '-Source', $Source)) -eq 0) `
    'skills(global) exits 0'
Check (Test-Path (Join-Path $homeDir '.agents/.jmix/skills/v3')) 'skills(global): v3 store created'

# Without an agent that reads ~/.agents/skills nothing replaces old Junie links,
# so they stay: removing them would leave Junie with no Jmix skills.
if ($linkType) {
    $junieLink = Join-Path $homeDir ".junie/skills/$skill"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $junieLink) | Out-Null
    New-Item -ItemType $linkType -Path $junieLink -Target (Join-Path $homeDir ".agents/.jmix/skills/v3/$skill") | Out-Null
    $null = Invoke-Installer @('skills', '-Agents', 'claude', '-Scope', 'global', '-Source', $Source)
    $junieItem = Get-Item -LiteralPath $junieLink -Force -ErrorAction SilentlyContinue
    Check ($null -ne $junieItem -and [bool]$junieItem.LinkType) 'skills(global): old Junie links kept when no agent reads ~/.agents/skills'
    if ($junieItem) { [System.IO.Directory]::Delete($junieLink, $false) }
    Remove-Item -LiteralPath (Join-Path $homeDir '.junie') -Recurse -Force
}

# Store backups (-BackupExistingFiles) are not skills: they are not linked,
# and a link to one that an earlier version made is removed.
if ($linkType) {
    $globalBak = Join-Path $homeDir ".agents/.jmix/skills/v3/$skill.bak"
    New-Item -ItemType Directory -Force -Path $globalBak | Out-Null
    New-Item -ItemType $linkType -Path (Join-Path $homeDir ".claude/skills/$skill.bak") -Target $globalBak | Out-Null
}
$null = Invoke-Installer @('skills', '-Agents', 'claude', '-Scope', 'global', '-BackupExistingFiles', '-Source', $Source)
Check (@(Get-ChildItem -LiteralPath (Join-Path $homeDir '.agents/.jmix/skills/v3') -Directory -Filter "$skill.bak*" |
        Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') }).Count -gt 0) `
    'skills(global): -BackupExistingFiles made a store backup beside the skill'
Check (@(Get-ChildItem -LiteralPath (Join-Path $homeDir '.claude/skills') -Force -Filter '*.bak*').Count -eq 0) `
    'skills(global): store backups not linked as skills'
Get-ChildItem -LiteralPath (Join-Path $homeDir '.agents/.jmix/skills/v3') -Force -Filter '*.bak*' | Remove-Item -Recurse -Force

# At global scope a store skill that is a link (here to the user's own fork) is
# backed up beside itself, as before, and the fork stays as it is.
if ($linkType) {
    $gstore = Join-Path $homeDir '.agents/.jmix/skills/v3'
    $fork = Join-Path $work 'fork'
    New-Item -ItemType Directory -Force -Path $fork | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $fork 'SKILL.md'), "fork`n")
    Remove-Item -LiteralPath (Join-Path $gstore $skill) -Recurse -Force
    New-Item -ItemType $linkType -Path (Join-Path $gstore $skill) -Target $fork | Out-Null
    $null = Invoke-Installer @('skills', '-Agents', 'claude', '-Scope', 'global', '-BackupExistingFiles', '-Source', $Source)
    $forkBak = Get-Item -LiteralPath (Join-Path $gstore "$skill.bak") -Force -ErrorAction SilentlyContinue
    Check ($null -ne $forkBak -and [bool]$forkBak.LinkType -and (Test-RealDir (Join-Path $gstore $skill)) -and
           (Get-Content -Raw -LiteralPath (Join-Path $fork 'SKILL.md')) -eq "fork`n") `
        "skills(global): a store skill linked to the user's fork is kept as $skill.bak"
    if ($forkBak) { [System.IO.Directory]::Delete($forkBak.FullName, $false) }
    Get-ChildItem -LiteralPath $gstore -Force -Filter '*.bak*' | Remove-Item -Recurse -Force
    Remove-Item -LiteralPath $fork -Recurse -Force
}

# Windows: global skills go to USERPROFILE, next to the agents' user configs,
# also when HOMEDRIVE+HOMEPATH (the $HOME of Windows PowerShell) is elsewhere.
if ($onWindows) {
    $otherHome = Join-Path $work 'home-drive'
    New-Item -ItemType Directory -Force -Path $otherHome | Out-Null
    $savedHomePath = $env:HOMEPATH
    $env:HOMEPATH = $otherHome.Substring($env:HOMEDRIVE.Length)
    $code = Invoke-Installer @('skills', '-Conventions', 'claude', '-Scope', 'global', '-Source', $Source)
    $env:HOMEPATH = $savedHomePath
    Check ($code -eq 0 -and (Test-Path (Join-Path $homeDir ".claude/skills/$skill/SKILL.md")) -and
           -not (Test-Path (Join-Path $otherHome '.claude'))) 'skills(global): Windows links the skills under USERPROFILE'
    Remove-Item -LiteralPath $otherHome -Recurse -Force
}

# An agent skills dir that is a relative symlink to another agent's dir (a
# common way to share skills, here ~/.agents/skills -> ../.claude/skills) is
# kept: its target is resolved from the link's folder, not the current one, so
# the skills the user keeps there stay visible.
if (Test-SymlinkCapable) {
    $agentsSkills = Join-Path $homeDir '.agents/skills'
    $ownSkill = Join-Path $homeDir '.claude/skills/my-own-skill'
    New-Item -ItemType Directory -Force -Path $ownSkill | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $ownSkill 'SKILL.md'), "# mine`n")
    New-Item -ItemType SymbolicLink -Path $agentsSkills -Target ([System.IO.Path]::Combine('..', '.claude', 'skills')) | Out-Null
    Check ((Invoke-Installer @('skills', '-Agents', 'codex', '-Scope', 'global', '-Source', $Source)) -eq 0) `
        'skills(global): exits 0 with a symlinked ~/.agents/skills'
    Check ((Get-Item -LiteralPath $agentsSkills -Force).LinkType -eq 'SymbolicLink') `
        'skills(global): a relative ~/.agents/skills -> ../.claude/skills link is kept'
    Check (Test-Path (Join-Path $agentsSkills 'my-own-skill/SKILL.md')) `
        "skills(global): the user's own skill stays visible through ~/.agents/skills"
    Check (Test-Path (Join-Path $agentsSkills "$skill/SKILL.md")) 'skills(global): Jmix skills resolve through the linked dir'
    [System.IO.Directory]::Delete($agentsSkills, $false)
    Remove-Item -LiteralPath $ownSkill -Recurse -Force
} else {
    Write-Host 'skip: no symlink privilege, skipping the symlinked ~/.agents/skills case'
}

# The other way round, ~/.agents/skills -> ~/.junie/skills: the old-Junie-link
# cleanup must not delete the links just created through ~/.agents/skills.
if (Test-SymlinkCapable) {
    $agentsSkills = Join-Path $homeDir '.agents/skills'
    New-Item -ItemType Directory -Force -Path (Join-Path $homeDir '.junie/skills') | Out-Null
    New-Item -ItemType SymbolicLink -Path $agentsSkills -Target ([System.IO.Path]::Combine('..', '.junie', 'skills')) | Out-Null
    $null = Invoke-Installer @('skills', '-Agents', 'codex', '-Scope', 'global', '-Source', $Source)
    Check (Test-Path (Join-Path $agentsSkills "$skill/SKILL.md")) `
        'skills(global): links kept through ~/.agents/skills -> ~/.junie/skills'
    # A broken cleanup removes ~/.junie/skills too, leaving the link dangling.
    try { [System.IO.Directory]::Delete($agentsSkills, $false) } catch { [System.IO.File]::Delete($agentsSkills) }
    Remove-Item -LiteralPath (Join-Path $homeDir '.junie') -Recurse -Force
}

# Studio can pin a feature branch independently of the release default.
Check ((Invoke-Installer @('skills', '-ContentRef', 'no-agents-md-test', '-Agents', 'claude',
        '-Scope', 'global', '-Source', $Source)) -eq 0) `
    'skills(global): content-ref override exits 0'
Check (Test-Path (Join-Path $homeDir '.agents/.jmix/skills/no-agents-md-test')) `
    'skills(global): content-ref override keys the store'

# ---------------------------------------------------------------------------
# 3. MCP servers. 3a-3q: at user level (-Scope global) in the isolated HOME;
#    3r on: in the project (-Scope local, the default). Files are merged in place.
# ---------------------------------------------------------------------------
$mcpProj = Join-Path $work 'mcp-project'
$binDir  = Join-Path $work 'bin'
# .git ends the walk over parent project configs that Codex merges in.
New-Item -ItemType Directory -Force -Path (Join-Path $mcpProj '.git'), $binDir | Out-Null
Set-Location $mcpProj
$claudeLog = Join-Path $work 'claude.log'
$codexLog  = Join-Path $work 'codex.log'
# Fake agent CLIs. Only Claude Code goes through its CLI (`claude mcp add`),
# whose arguments the fake records (and echoes, like the real one does).
if ($onWindows) {
    [System.IO.File]::WriteAllText((Join-Path $binDir 'claude.cmd'), "@echo off`r`necho %* >>`"$claudeLog`"`r`necho added: %*`r`n")
    [System.IO.File]::WriteAllText((Join-Path $binDir 'codex.cmd'), "@echo off`r`necho called >>`"$codexLog`"`r`nexit /b 99`r`n")
} else {
    [System.IO.File]::WriteAllText((Join-Path $binDir 'claude'), "#!/bin/sh`necho `"`$*`" >> '$claudeLog'`necho `"added: `$*`"`n")
    [System.IO.File]::WriteAllText((Join-Path $binDir 'codex'), "#!/bin/sh`necho called >> '$codexLog'`nexit 99`n")
    & chmod +x (Join-Path $binDir 'claude') (Join-Path $binDir 'codex')
}
$origPath = $env:PATH
$binPath  = $binDir + [System.IO.Path]::PathSeparator + $origPath
# A PATH without any claude CLI (the child pwsh is started by its full path).
$barePath = if ($onWindows) { Join-Path $env:SystemRoot 'System32' } else { '/usr/bin:/bin' }
$desktopDir = if ($onWindows) { Join-Path $env:APPDATA 'Claude' }
              elseif ($IsMacOS) { Join-Path $homeDir 'Library/Application Support/Claude' }
              else { Join-Path $homeDir '.config/Claude' }
$userCodex = Join-Path $homeDir '.codex/config.toml'
$userOc    = Join-Path $homeDir '.config/opencode/opencode.json'
$userJunie = Join-Path $homeDir '.junie/mcp/mcp.json'
# Root can read and write anything, so the permission cases need a normal user.
$isUnixUser = -not $onWindows -and ((& id -u) -ne '0')

function Set-TestFile {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"))
}
function Read-Json {
    param([string]$Path)
    return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}
# True when $Actual serializes like the JSON text $Expected (property order counts).
function Test-JsonEqual {
    param($Actual, [string]$Expected)
    return ((ConvertTo-Json -InputObject $Actual -Depth 20 -Compress) -ceq
            (ConvertTo-Json -InputObject (ConvertFrom-Json $Expected) -Depth 20 -Compress))
}
function Get-Sha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}
# The arguments the fake claude CLI got so far (cmd.exe keeps the quotes).
function Get-ClaudeCalls {
    if (Test-Path $claudeLog) { return ([System.IO.File]::ReadAllText($claudeLog) -replace '"', '') }
    return ''
}
# True when the MCP steps left the project as it was (only .git in it).
function Test-ProjectUntouched {
    return (@(Get-ChildItem -LiteralPath $mcpProj -Force | Where-Object { $_.Name -ne '.git' }).Count -eq 0)
}

$env:PATH = $binPath

# 3a. IDE MCP server not reachable -> Streamable HTTP (/stream). Foreign
#     servers and keys survive; an old [mcp_servers.jetbrains] table and its
#     sub-table are replaced; nothing lands in the project.
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $userCodex), (Split-Path -Parent $userOc) | Out-Null
Set-TestFile $userOc @'
{
  "$schema": "keep-me",
  "mcp": {"mine": {"type": "remote", "url": "http://mine"}}
}
'@
Set-TestFile $userCodex @'
model = "o3"

[mcp_servers.jetbrains]
command = "java"

[mcp_servers.jetbrains.env]
IJ_MCP_SERVER_PORT = "64342"

[mcp_servers.mine]
url = "http://mine"
'@
Check ((Invoke-Installer @('mcp-jetbrains', '-Scope', 'global', '-Agents', 'claude,codex,opencode,junie')) -eq 0) 'mcp-jetbrains exits 0'
Check ((Get-ClaudeCalls).Contains('mcp add --scope user --transport http jetbrains http://127.0.0.1:9/stream')) `
    'mcp-jetbrains: claude mcp add arguments'
Check (-not (Test-Path $codexLog)) 'mcp-jetbrains: the codex CLI is not called'
$toml = [System.IO.File]::ReadAllText($userCodex)
Check ($toml -cmatch '(?m)^model = "o3"$' -and $toml -cmatch '(?m)^\[mcp_servers\.mine\]$') 'mcp-jetbrains: other Codex config kept'
Check (([regex]::Matches($toml, '(?m)^\[mcp_servers\.jetbrains')).Count -eq 1 -and -not $toml.Contains('IJ_MCP_SERVER_PORT')) `
    'mcp-jetbrains: old Codex jetbrains table replaced'
Check ($toml -cmatch '(?m)^url = "http://127\.0\.0\.1:9/stream"$') 'mcp-jetbrains: Codex url'
$json = Read-Json $userOc
Check ((Test-JsonEqual $json.mcp.jetbrains '{"type":"remote","url":"http://127.0.0.1:9/stream","enabled":true}') -and
       $json.mcp.mine.url -eq 'http://mine' -and $json.'$schema' -eq 'keep-me') 'mcp-jetbrains: OpenCode entry added, other content kept'
Check (-not (Test-Path $userJunie)) 'mcp-jetbrains: Junie got no JetBrains MCP entry'
Check (Test-ProjectUntouched) 'mcp-jetbrains: nothing written into the project'

# 3b. A re-run changes nothing.
$hashes = @((Get-Sha $userCodex), (Get-Sha $userOc))
$r = Invoke-InstallerResult @('mcp-jetbrains', '-Scope', 'global', '-Agents', 'codex,opencode')
Check ($r.Code -eq 0) 'mcp-jetbrains: re-run exits 0'
Check ((@((Get-Sha $userCodex), (Get-Sha $userOc)) -join ',') -eq ($hashes -join ',') -and $r.Output -notmatch 'Updated: |Created: ') `
    'mcp-jetbrains: re-run leaves the files unchanged'

# 3c. A file the merge cannot parse (JSONC) is left alone and the step fails;
#     the agents after it are still configured.
$savedOc = [System.IO.File]::ReadAllText($userOc)
Set-TestFile $userOc "{`n  // mine`n  `"theme`": `"dark`"`n}`n"
$ocHash = Get-Sha $userOc
Remove-Item -LiteralPath $claudeLog -Force -ErrorAction SilentlyContinue
Check ((Invoke-Installer @('mcp-jetbrains', '-Scope', 'global', '-Agents', 'opencode,claude')) -ne 0) 'mcp-jetbrains: a JSONC opencode.json fails the step'
Check ((Get-Sha $userOc) -eq $ocHash) 'mcp-jetbrains: JSONC opencode.json untouched'
Check ((Get-ClaudeCalls).Contains('jetbrains')) 'mcp-jetbrains: a failed agent does not stop the agents after it'
Set-TestFile $userOc $savedOc

# 3d. A server defined inline (not as a [table]) is refused, not duplicated.
$savedCodex = [System.IO.File]::ReadAllText($userCodex)
Set-TestFile $userCodex "[mcp_servers]`njetbrains = { url = `"http://mine`" }`n"
$codexHash = Get-Sha $userCodex
Check ((Invoke-Installer @('mcp-jetbrains', '-Scope', 'global', '-Agents', 'codex')) -ne 0) 'mcp-jetbrains: an inline Codex jetbrains entry fails the step'
Check ((Get-Sha $userCodex) -eq $codexHash) 'mcp-jetbrains: inline Codex entry untouched'
Set-TestFile $userCodex $savedCodex

# 3e. IntelliJ IDEA before 2026.1 answers 404 on /stream: SSE for Claude and
#     OpenCode, a stdio bridge for Codex (no SSE transport there). A local
#     TCP listener stands in for the IDE; the probe must bypass a proxy, which
#     would answer instead of it (here one that is not even there).
$portFile = Join-Path $work 'port'
$server = Start-Job -ScriptBlock {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    [System.IO.File]::WriteAllText($using:portFile, [string]$listener.LocalEndpoint.Port)
    $reply = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
    while ($true) {
        # Poll instead of blocking in AcceptTcpClient, which Stop-Job cannot interrupt.
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
        $client = $listener.AcceptTcpClient()
        $stream = $client.GetStream()
        $buffer = New-Object byte[] 4096
        $request = ''
        while (-not $request.Contains("`r`n`r`n")) {
            $n = $stream.Read($buffer, 0, $buffer.Length)
            if ($n -le 0) { break }
            $request += [System.Text.Encoding]::ASCII.GetString($buffer, 0, $n)
        }
        $stream.Write($reply, 0, $reply.Length)
        $client.Close()
    }
}
$port = ''
for ($i = 0; $i -lt 60 -and -not $port; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-Path $portFile) { $port = ([System.IO.File]::ReadAllText($portFile)).Trim() }
}
if ($port) {
    $env:JMIX_IDE_MCP_PORT = $port
    $env:HTTP_PROXY = 'http://127.0.0.1:9'
    Check ((Invoke-Installer @('mcp-jetbrains', '-Scope', 'global', '-Agents', 'claude,codex,opencode')) -eq 0) 'mcp-jetbrains(sse) exits 0'
    Remove-Item Env:HTTP_PROXY
    $env:JMIX_IDE_MCP_PORT = '9'
    $sse = "http://127.0.0.1:$port/sse"
    Check ((Get-ClaudeCalls).Contains("mcp add --scope user --transport sse jetbrains $sse")) 'mcp-jetbrains(sse): Claude entry is SSE'
    Check ([System.IO.File]::ReadAllText($userCodex) -cmatch ('(?m)^args = \["-y", "mcp-remote", "' + [regex]::Escape($sse) + '", "--transport", "sse-only"\]$')) `
        'mcp-jetbrains(sse): Codex gets the mcp-remote bridge'
    Check ((Read-Json $userOc).mcp.jetbrains.url -eq $sse) 'mcp-jetbrains(sse): OpenCode entry is SSE'
    Check ((Invoke-Installer @('mcp-jetbrains', '-Scope', 'global', '-Agents', 'codex,opencode')) -eq 0) 'mcp-jetbrains: switching back to /stream exits 0'
} else {
    Check $false 'mcp-jetbrains(sse): local 404 server did not start'
}
Stop-Job $server
Remove-Job $server -Force

# 3f. Claude Desktop is set up together with claude, and only when it is
#     installed (its config folder exists); its own settings are kept and the
#     restart reminder appears only when its file changed.
$r = Invoke-InstallerResult @('mcp-jetbrains', '-Scope', 'global', '-Agents', 'claude')
Check ($r.Code -eq 0) 'mcp-jetbrains: a missing Claude Desktop does not fail the step'
Check (-not (Test-Path $desktopDir)) 'mcp-jetbrains: no Claude Desktop config folder created'
Check ($r.Output -notmatch 'Claude Desktop') 'mcp-jetbrains: a Claude Desktop that is not installed is not mentioned'
$desktopCfg = Join-Path $desktopDir 'claude_desktop_config.json'
New-Item -ItemType Directory -Force -Path $desktopDir | Out-Null
Set-TestFile $desktopCfg '{"preferences": {"keep": true}}'
$r = Invoke-InstallerResult @('mcp-jetbrains', '-Scope', 'global', '-Agents', 'claude')
Check ($r.Code -eq 0) 'mcp-jetbrains(desktop) exits 0'
Check ($r.Output -match 'Quit Claude Desktop') 'mcp-jetbrains(desktop): restart reminder after writing its config'
$json = Read-Json $desktopCfg
Check ($json.preferences.keep -eq $true -and
       (Test-JsonEqual $json.mcpServers.jetbrains '{"command":"npx","args":["-y","mcp-remote","http://127.0.0.1:9/sse","--transport","sse-only"]}')) `
    'mcp-jetbrains(desktop): stdio bridge added, preferences kept'
$r = Invoke-InstallerResult @('mcp-jetbrains', '-Scope', 'global', '-Agents', 'claude')
Check ($r.Output -notmatch 'Quit Claude Desktop') 'mcp-jetbrains(desktop): no restart reminder for an unchanged file'
Check ((Invoke-Installer @('mcp-jetbrains', '-Scope', 'global', '-Agents', 'claude-desktop')) -ne 0) `
    'mcp-jetbrains: claude-desktop is no longer a separate agent'

# Windows: the Store build of Claude Desktop reads a per-package copy. A package
# folder without a config must not get one while %APPDATA%\Claude has it (it
# would shadow that file); an existing package config is updated alongside.
if ($onWindows) {
    $pkgDir = Join-Path $env:LOCALAPPDATA 'Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude'
    $pkgCfg = Join-Path $pkgDir 'claude_desktop_config.json'
    New-Item -ItemType Directory -Force -Path $pkgDir | Out-Null
    $null = Invoke-Installer @('mcp-jetbrains', '-Scope', 'global', '-Agents', 'claude')
    Check (-not (Test-Path $pkgCfg)) 'mcp-jetbrains(desktop): no shadowing config created in the package folder'
    Set-TestFile $pkgCfg '{}'
    $null = Invoke-Installer @('mcp-jetbrains', '-Scope', 'global', '-Agents', 'claude')
    Check ((Read-Json $pkgCfg).mcpServers.jetbrains.command -eq 'npx') 'mcp-jetbrains(desktop): package config updated too'
    Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'Packages') -Recurse -Force
}

# 3g. Context7: the key never reaches the output or the project, and the user
#     files holding it are private.
$r = Invoke-InstallerResult @('mcp-context7', '-Scope', 'global', '-Agents', 'claude,codex,opencode,junie', '-Context7Key', 'ctx7sk-TESTKEY')
Check ($r.Code -eq 0) 'mcp-context7 exits 0'
Check (-not ($r.Output -match 'TESTKEY')) 'mcp-context7: the API key is not printed'
Check ((Get-ClaudeCalls).Contains('mcp add --scope user --transport http context7 https://mcp.context7.com/mcp --header Authorization: Bearer ctx7sk-TESTKEY')) `
    'mcp-context7: claude mcp add arguments'
Check ([System.IO.File]::ReadAllText($userCodex).Contains('http_headers = { Authorization = "Bearer ctx7sk-TESTKEY" }')) `
    'mcp-context7: Codex user config entry'
Check ((Read-Json $userOc).mcp.context7.headers.Authorization -eq 'Bearer ctx7sk-TESTKEY') 'mcp-context7: OpenCode user config entry'
Check ((Read-Json $userJunie).mcpServers.context7.env.CONTEXT7_API_KEY -eq 'ctx7sk-TESTKEY') 'mcp-context7: Junie user config entry'
$json = Read-Json $desktopCfg
Check ($json.mcpServers.context7.env.CONTEXT7_API_KEY -eq 'ctx7sk-TESTKEY' -and $json.preferences.keep -eq $true) `
    'mcp-context7: Claude Desktop entry'
Check (Test-ProjectUntouched) 'mcp-context7: nothing written into the project'
if (-not $onWindows) {
    foreach ($f in $userCodex, $userOc, $userJunie, $desktopCfg) {
        Check ((Get-Item -LiteralPath $f).UnixMode -eq '-rw-------') "mcp-context7: $f holds the key and is 0600"
    }
}
Check ((Invoke-Installer @('mcp-context7', '-Scope', 'global', '-Agents', 'codex', '-Context7Key', 'bad/key')) -ne 0) `
    'mcp-context7: a key with characters that need escaping is rejected'

# 3h. An invalid -Scope is refused; the claude CLI is also found where its
#     installers put it, off PATH (an IDE started from the desktop often lacks
#     ~/.local/bin).
Check ((Invoke-Installer @('playwright', '-Agents', 'codex', '-Scope', 'nowhere')) -ne 0) 'playwright: an invalid -Scope fails'
$env:PATH = $barePath
$r = Invoke-InstallerResult @('playwright', '-Scope', 'global', '-Agents', 'claude')
$env:PATH = $binPath
Check ($r.Code -eq 0 -and $r.Output -match "Skipped: 'claude' CLI not found") 'playwright: a missing claude CLI is a skip, not a failure'
if (-not $onWindows) {
    $localBin = Join-Path $homeDir '.local/bin'
    $localLog = Join-Path $work 'claude-local.log'
    New-Item -ItemType Directory -Force -Path $localBin | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $localBin 'claude'), "#!/bin/sh`necho `"`$*`" >> '$localLog'`n")
    & chmod +x (Join-Path $localBin 'claude')
    $env:PATH = $barePath
    $code = Invoke-Installer @('playwright', '-Scope', 'global', '-Agents', 'claude')
    $env:PATH = $binPath
    Check ($code -eq 0 -and (Test-Path $localLog) -and
           [System.IO.File]::ReadAllText($localLog).Contains('mcp add --scope user playwright -- npx -y @playwright/mcp@latest')) `
        'playwright: the claude CLI in ~/.local/bin is used off PATH'
    Remove-Item -LiteralPath (Join-Path $homeDir '.local') -Recurse -Force
    $oldDir = Join-Path $homeDir '.claude/local'
    $oldLog = Join-Path $work 'claude-old.log'
    New-Item -ItemType Directory -Force -Path $oldDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $oldDir 'claude'), "#!/bin/sh`necho `"`$*`" >> '$oldLog'`n")
    & chmod +x (Join-Path $oldDir 'claude')
    $env:PATH = $barePath
    $code = Invoke-Installer @('playwright', '-Scope', 'global', '-Agents', 'claude')
    $env:PATH = $binPath
    Check ($code -eq 0 -and (Test-Path $oldLog)) 'playwright: the claude CLI in ~/.claude/local is used off PATH'
    Remove-Item -LiteralPath $oldDir -Recurse -Force
}

# 3i. Playwright for every agent. The playwright-cli skills of earlier versions
#     are left alone (old install.ps1 links had absolute targets, junctions on
#     Windows).
$oldStore = Join-Path $homeDir '.agents/.playwright/skills/playwright-cli'
$userSkills = Join-Path $homeDir '.claude/skills'
$oldLink = Join-Path $userSkills 'playwright-cli'
$linkType = if ($onWindows) { 'Junction' } else { 'SymbolicLink' }
New-Item -ItemType Directory -Force -Path $oldStore, $userSkills | Out-Null
New-Item -ItemType $linkType -Path $oldLink -Target $oldStore | Out-Null
Check ((Invoke-Installer @('playwright', '-Scope', 'global', '-Agents', 'claude,codex,opencode,junie')) -eq 0) 'playwright exits 0'
Check ((Get-ClaudeCalls).Contains('mcp add --scope user playwright -- npx -y @playwright/mcp@latest')) 'playwright: claude mcp add arguments'
Check ([System.IO.File]::ReadAllText($userCodex) -cmatch '(?m)^args = \["-y", "@playwright/mcp@latest"\]$') 'playwright: Codex entry'
Check (Test-JsonEqual (Read-Json $userOc).mcp.playwright.command '["npx","-y","@playwright/mcp@latest"]') 'playwright: OpenCode entry'
Check (Test-JsonEqual (Read-Json $userJunie).mcpServers.playwright.args '["-y","@playwright/mcp@latest"]') 'playwright: Junie entry'
Check ((Test-Path $oldLink) -and (Test-Path (Join-Path $homeDir '.agents/.playwright'))) 'playwright: the old playwright-cli skills are kept'
[System.IO.Directory]::Delete($oldLink, $false)
Remove-Item -LiteralPath (Join-Path $homeDir '.agents/.playwright') -Recurse -Force
Check (Test-ProjectUntouched) 'playwright: nothing written into the project'

# 3j. Codex merges the project configs of the current dir up to its git root
#     into the user config: one with the other transport fails the step; they
#     are read, never written.
$userBefore = Get-Sha $userCodex
$projCodexDir = Join-Path $mcpProj '.codex'
$projCodex = Join-Path $projCodexDir 'config.toml'
$appDir = Join-Path $mcpProj 'app'
New-Item -ItemType Directory -Force -Path $projCodexDir, $appDir | Out-Null
Set-TestFile $projCodex "[mcp_servers.playwright]`nurl = `"http://project`"`n"
$projBefore = Get-Sha $projCodex
foreach ($dir in $mcpProj, $appDir) {
    Set-Location $dir
    Check ((Invoke-Installer @('playwright', '-Scope', 'global', '-Agents', 'codex')) -ne 0) "codex: a project table with another transport fails the step (from $dir)"
    Check ((Get-Sha $userCodex) -eq $userBefore -and (Get-Sha $projCodex) -eq $projBefore) 'codex: the project conflict changed no config'
}
Check (-not (Test-Path (Join-Path $appDir '.codex'))) 'codex: no project config written'
Set-TestFile $projCodex "notes = `"`"`"`nmulti`nline`n`"`"`"`n`n[mcp_servers.playwright]`ncommand = `"npx`"`n"
$projBefore = Get-Sha $projCodex
Set-Location $appDir
Check ((Invoke-Installer @('playwright', '-Scope', 'global', '-Agents', 'codex')) -eq 0) `
    'codex: a same-transport project table (with a triple-quoted string) is accepted'
Check ((Get-Sha $projCodex) -eq $projBefore) 'codex: the project config is not rewritten'
foreach ($entry in "[mcp_servers]`nplaywright = { url = `"http://project`" }`n", "mcp_servers.playwright.url = `"http://project`"`n") {
    Set-TestFile $projCodex $entry
    $projBefore = Get-Sha $projCodex
    $r = Invoke-InstallerResult @('playwright', '-Scope', 'global', '-Agents', 'codex')
    Check ($r.Code -ne 0 -and $r.Output -match 'cannot check') "codex: an unreadable project definition fails the step: $($entry.Split("`n")[0])"
    Check ((Get-Sha $projCodex) -eq $projBefore -and (Get-Sha $userCodex) -eq $userBefore) 'codex: an unreadable project definition changed no config'
}
# With the IDE unreachable the transport is a guess: the error points at the
# IDE, not at a project bridge that may well be right.
Set-TestFile $projCodex "[mcp_servers.jetbrains]`ncommand = `"npx`"`n"
$r = Invoke-InstallerResult @('mcp-jetbrains', '-Scope', 'global', '-Agents', 'codex')
Check ($r.Code -ne 0 -and $r.Output -match 'not reachable to tell') 'codex: a guessed-transport conflict points at the IDE'
Set-Location $mcpProj
Remove-Item -LiteralPath $projCodexDir, $appDir -Recurse -Force
# Outside a git repository Codex reads only the current directory's config.
$noGit = Join-Path $work 'nogit'
New-Item -ItemType Directory -Force -Path (Join-Path $noGit '.codex'), (Join-Path $noGit 'child') | Out-Null
Set-TestFile (Join-Path $noGit '.codex/config.toml') "[mcp_servers.playwright]`nurl = `"http://parent`"`n"
Set-Location (Join-Path $noGit 'child')
Check ((Invoke-Installer @('playwright', '-Scope', 'global', '-Agents', 'codex')) -eq 0) 'codex: a parent config outside a git repository is ignored'
Set-Location $mcpProj
Remove-Item -LiteralPath $noGit -Recurse -Force

# 3k. Run from HOME, the project config is the user config: an old stdio
#     context7 entry there is simply replaced.
$savedCodex = [System.IO.File]::ReadAllText($userCodex)
Set-TestFile $userCodex "[mcp_servers.context7]`ncommand = `"npx`"`nargs = [`"-y`", `"@upstash/context7-mcp`", `"--api-key`", `"old`"]`n"
Push-Location $homeDir
$code = Invoke-Installer @('mcp-context7', '-Scope', 'global', '-Agents', 'codex', '-Context7Key', 'ctx7sk-TESTKEY')
Pop-Location
$toml = [System.IO.File]::ReadAllText($userCodex)
Check ($code -eq 0 -and $toml -cmatch '(?m)^url = "https://mcp\.context7\.com/mcp"$' -and $toml -cnotmatch '(?m)^command') `
    'mcp-context7: run from HOME replaces the old stdio entry'

# 3l. A table is replaced where it stands: the order and the comment that
#     introduces the next table stay, and alternating steps converge.
Set-TestFile $userCodex "[mcp_servers.jetbrains]`nurl = `"old`"`n`n# my own server`n[mcp_servers.mine]`nurl = `"http://mine`"`n"
Check ((Invoke-Installer @('mcp-jetbrains', '-Scope', 'global', '-Agents', 'codex')) -eq 0) 'toml: exits 0'
$toml = [System.IO.File]::ReadAllText($userCodex)
Check ($toml.StartsWith("[mcp_servers.jetbrains]`n")) 'toml: a replaced table stays where it stood'
Check ($toml -cmatch '(?m)^# my own server$') 'toml: the comment before the next table kept'
$null = Invoke-Installer @('playwright', '-Scope', 'global', '-Agents', 'codex')
$tomlHash = Get-Sha $userCodex
$out = (Invoke-InstallerCapture @('mcp-jetbrains', '-Scope', 'global', '-Agents', 'codex')) + (Invoke-InstallerCapture @('playwright', '-Scope', 'global', '-Agents', 'codex'))
Check ((Get-Sha $userCodex) -eq $tomlHash) 'toml: alternating steps converge'
Check ($out -notmatch 'Updated: ') 'toml: an unchanged config.toml is not reported as updated'

# 3m. Unsupported TOML is refused and the file kept: a triple-quoted string (in
#     a file the step has to write), a root inline table, dotted keys. A quoted
#     key is fine, and a BOM before the first header does not duplicate the
#     table, and stays.
foreach ($entry in "notes = `"`"`"`nmulti`n`"`"`"`n", "notes = '''`nmulti`n'''`n",
                   "mcp_servers = { jetbrains = { url = `"x`" } }`n",
                   "[mcp_servers]`njetbrains = { command = `"java`", args = [] }`n",
                   "mcp_servers.jetbrains.command = `"java`"`n") {
    Set-TestFile $userCodex $entry
    $codexHash = Get-Sha $userCodex
    $label = $entry.Split("`n")[0]
    Check ((Invoke-Installer @('mcp-jetbrains', '-Scope', 'global', '-Agents', 'codex')) -ne 0) "toml: unsupported syntax fails the step: $label"
    Check ((Get-Sha $userCodex) -eq $codexHash) "toml: unsupported syntax is left untouched: $label"
}
Set-TestFile $userCodex "[mcp_servers.jetbrains]`n`"url`" = `"http://old`"`n"
Check ((Invoke-Installer @('mcp-jetbrains', '-Scope', 'global', '-Agents', 'codex')) -eq 0) 'toml: a quoted key exits 0'
Check (-not [System.IO.File]::ReadAllText($userCodex).Contains('http://old')) 'toml: a quoted url key is replaced'
[System.IO.File]::WriteAllBytes($userCodex, [byte[]](0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::ASCII.GetBytes("[mcp_servers.jetbrains]`nurl = `"old`"`n"))
Check ((Invoke-Installer @('mcp-jetbrains', '-Scope', 'global', '-Agents', 'codex')) -eq 0) 'toml: a file with a BOM exits 0'
$afterBytes = [System.IO.File]::ReadAllBytes($userCodex)
Check ($afterBytes[0] -eq 0xEF -and $afterBytes[1] -eq 0xBB -and $afterBytes[2] -eq 0xBF) 'toml: the leading BOM kept'
Check (([regex]::Matches([System.Text.Encoding]::UTF8.GetString($afterBytes), 'mcp_servers\.jetbrains')).Count -eq 1) `
    'toml: a BOM before the header does not duplicate the table'
Set-TestFile $userCodex $savedCodex

# 3n. An unreadable config, or a directory at its path, is reported and kept,
#     never replaced.
if ($isUnixUser) {
    & chmod 000 $userOc
    $r = Invoke-InstallerResult @('playwright', '-Scope', 'global', '-Agents', 'opencode')
    & chmod 600 $userOc
    Check ($r.Code -ne 0 -and $r.Output -match 'cannot read') 'json: an unreadable opencode.json fails the step'
    Check ($null -ne (Read-Json $userOc).mcp.mine) 'json: an unreadable opencode.json is kept'
}
$savedOcPath = Join-Path $work 'opencode.saved.json'
Move-Item -LiteralPath $userOc -Destination $savedOcPath
New-Item -ItemType Directory -Path $userOc | Out-Null
$r = Invoke-InstallerResult @('playwright', '-Scope', 'global', '-Agents', 'opencode')
Check ($r.Code -ne 0 -and $r.Output -match 'not a regular file') 'json: a directory at the config path fails the step'
Check (-not (Get-ChildItem -LiteralPath $userOc -Force)) 'json: the config directory is left empty'
Remove-Item -LiteralPath $userOc -Force
Move-Item -LiteralPath $savedOcPath -Destination $userOc

# 3o. A user config that gets the Context7 key ends up private, also when it
#     already held the entry (Unchanged) or is rewritten.
if (-not $onWindows) {
    & chmod 644 $userOc
    $r = Invoke-InstallerResult @('mcp-context7', '-Scope', 'global', '-Agents', 'opencode', '-Context7Key', 'ctx7sk-TESTKEY')
    Check ($r.Code -eq 0 -and $r.Output -match 'Unchanged: ') 'mcp-context7: re-run finds opencode.json unchanged'
    Check ((Get-Item -LiteralPath $userOc).UnixMode -eq '-rw-------') 'mcp-context7: an unchanged 0644 opencode.json is made private'
    Set-TestFile $userJunie '{"mcpServers": {}}'
    & chmod 644 $userJunie
    $null = Invoke-Installer @('mcp-context7', '-Scope', 'global', '-Agents', 'junie', '-Context7Key', 'ctx7sk-TESTKEY')
    Check ((Get-Item -LiteralPath $userJunie).UnixMode -eq '-rw-------') 'mcp-context7: a rewritten 0644 mcp.json is made private'
}

# 3q. A JMIX_IDE_MCP_PORT that is not a port is refused up front; -Source is
#     accepted by the MCP steps too.
foreach ($badPort in '9"x', '70000', '0') {
    $env:JMIX_IDE_MCP_PORT = $badPort
    Check ((Invoke-Installer @('mcp-jetbrains', '-Scope', 'global', '-Agents', 'codex')) -ne 0) "JMIX_IDE_MCP_PORT '$badPort' is refused"
}
$env:JMIX_IDE_MCP_PORT = '9'
Check ((Invoke-Installer @('mcp-jetbrains', '-Scope', 'global', '-Agents', 'codex', '-Source', $Source)) -eq 0) 'mcp-jetbrains: -Source is accepted'

# 3r. Local scope (the default): the project files of every agent, merged in
#     place; Claude Code needs no CLI there.
$localProj = Join-Path $work 'local-project'
New-Item -ItemType Directory -Force -Path (Join-Path $localProj '.git'), (Join-Path $localProj '.codex') | Out-Null
Set-Location $localProj
$localMcp = Join-Path $localProj '.mcp.json'
$localCodex = Join-Path $localProj '.codex/config.toml'
$localOc = Join-Path $localProj 'opencode.json'
$localJunie = Join-Path $localProj '.junie/mcp/mcp.json'
Set-TestFile $localMcp "{`n  `"`$schema`": `"keep-me`",`n  `"mcpServers`": {`"mine`": {`"type`": `"http`", `"url`": `"http://mine`"}}`n}`n"
Set-TestFile $localCodex "model = `"o3`"`n`n[mcp_servers.mine]`nurl = `"http://mine`"`n"
Remove-Item -LiteralPath $claudeLog -Force -ErrorAction SilentlyContinue
$r = Invoke-InstallerResult @('mcp', '-Servers', 'playwright,jetbrains', '-Agents', 'claude,codex,opencode,junie')
Check ($r.Code -eq 0) 'mcp(local) exits 0'
Check (-not (Test-Path $claudeLog)) 'mcp(local): the claude CLI is not called'
$json = Read-Json $localMcp
Check ((Test-JsonEqual $json.mcpServers.jetbrains '{"type":"http","url":"http://127.0.0.1:9/stream"}') -and
       (Test-JsonEqual $json.mcpServers.playwright '{"type":"stdio","command":"npx","args":["-y","@playwright/mcp@latest"]}') -and
       $json.mcpServers.mine.url -eq 'http://mine' -and $json.'$schema' -eq 'keep-me') 'mcp(local): .mcp.json entries added, other content kept'
$toml = [System.IO.File]::ReadAllText($localCodex)
Check ($toml -cmatch '(?m)^model = "o3"$' -and $toml -cmatch '(?m)^url = "http://127\.0\.0\.1:9/stream"$' -and
       $toml -cmatch '(?m)^\[mcp_servers\.playwright\]$') 'mcp(local): Codex project config'
$json = Read-Json $localOc
Check ($json.mcp.jetbrains.type -eq 'remote' -and $json.mcp.playwright.type -eq 'local') 'mcp(local): opencode.json'
$json = Read-Json $localJunie
Check ($json.mcpServers.playwright.command -eq 'npx' -and -not $json.mcpServers.PSObject.Properties['jetbrains']) 'mcp(local): Junie project config'
Check ($r.Output -match 'approve the servers in \.mcp\.json' -and $r.Output -match 'trust this folder') 'mcp(local): follow-up notes'
Check ($r.Output -match '(?s)\[JetBrains MCP\].*\[Playwright MCP\]') 'mcp(local): servers run in the documented order'
$hashes = @((Get-Sha $localMcp), (Get-Sha $localCodex), (Get-Sha $localOc))
$r = Invoke-InstallerResult @('mcp', '-Servers', 'jetbrains,playwright', '-Agents', 'claude,codex,opencode,junie')
Check ($r.Code -eq 0 -and (@((Get-Sha $localMcp), (Get-Sha $localCodex), (Get-Sha $localOc)) -join ',') -eq ($hashes -join ',') -and
       $r.Output -notmatch 'Updated: |Created: ') 'mcp(local): re-run leaves the files unchanged'

# Context7 follows the scope: the key goes into the project files, which end up
# private, and the step says to keep them out of version control.
Remove-Item -LiteralPath (Join-Path $localProj '.junie') -Recurse -Force
$r = Invoke-InstallerResult @('mcp', '-Servers', 'context7', '-Agents', 'claude,codex,opencode,junie', '-Context7Key', 'ctx7sk-TESTKEY')
Check ($r.Code -eq 0) 'mcp-context7(local) exits 0'
Check ($r.Output -notmatch 'TESTKEY') 'mcp-context7(local): the key is not printed'
Check ($r.Output -match 'keep these files out of version control') 'mcp-context7(local): warns about the key in project files'
Check (Test-JsonEqual (Read-Json $localMcp).mcpServers.context7 '{"type":"http","url":"https://mcp.context7.com/mcp","headers":{"Authorization":"Bearer ctx7sk-TESTKEY"}}') `
    'mcp-context7(local): .mcp.json entry'
Check ([System.IO.File]::ReadAllText($localCodex).Contains('http_headers = { Authorization = "Bearer ctx7sk-TESTKEY" }')) 'mcp-context7(local): Codex entry'
Check ((Read-Json $localOc).mcp.context7.headers.Authorization -eq 'Bearer ctx7sk-TESTKEY') 'mcp-context7(local): OpenCode entry'
Check ((Read-Json $localJunie).mcpServers.context7.env.CONTEXT7_API_KEY -eq 'ctx7sk-TESTKEY') 'mcp-context7(local): Junie entry'
if (-not $onWindows) {
    foreach ($f in $localMcp, $localCodex, $localOc, $localJunie) {
        Check ((Get-Item -LiteralPath $f -Force).UnixMode -eq '-rw-------') "mcp-context7(local): $f holds the key and is 0600"
    }
}

# Codex merges the user config into the project: one with the other transport
# fails a local registration, and neither file changes.
$userSaved = [System.IO.File]::ReadAllText($userCodex)
Set-TestFile $userCodex "[mcp_servers.playwright]`nurl = `"http://user`"`n"
$userBefore = Get-Sha $userCodex
$projBefore = Get-Sha $localCodex
$r = Invoke-InstallerResult @('playwright', '-Agents', 'codex')
Check ($r.Code -ne 0 -and $r.Output.Contains("$userCodex defines [mcp_servers.playwright] with another transport")) `
    'codex(local): a user table with another transport fails the step and is named'
Check ((Get-Sha $userCodex) -eq $userBefore -and (Get-Sha $localCodex) -eq $projBefore) 'codex(local): the refused step changed no config'
Set-TestFile $userCodex $userSaved

# 3s. mcp: -Servers is required and checked; 'skip' leaves Context7 out; each
#     option belongs to its steps.
Check ((Invoke-Installer @('mcp', '-Agents', 'codex')) -ne 0) 'mcp: -Servers is required'
Check ((Invoke-Installer @('mcp', '-Servers', 'jetbrains,bogus', '-Agents', 'codex')) -ne 0) 'mcp: an unknown server fails'
$projBefore = Get-Sha $localCodex
$userBefore = Get-Sha $userCodex
$r = Invoke-InstallerResult @('mcp', '-Servers', 'context7', '-Agents', 'codex', '-Context7Key', 'skip')
Check ($r.Code -eq 0 -and $r.Output -match '\[Context7 MCP\] Skipped') "mcp: 'skip' skips Context7"
Check ((Get-Sha $localCodex) -eq $projBefore -and (Get-Sha $userCodex) -eq $userBefore) "mcp: 'skip' writes no config"
$r = Invoke-InstallerResult @('mcp', '-Servers', 'Context7', '-Agents', 'CODEX', '-Scope', 'LOCAL', '-Context7Key', 'skip')
Check ($r.Code -eq 0 -and $r.Output -match '\[Context7 MCP\] Skipped') 'mcp: values are case-insensitive'
Check ((Invoke-Installer @('mcp-jetbrains', '-Agents', 'codex', '-Servers', 'jetbrains')) -ne 0) 'mcp-jetbrains: -Servers is for mcp only'
Check ((Invoke-Installer @('playwright', '-Agents', 'codex', '-Context7Key', 'x')) -ne 0) 'playwright: -Context7Key is for Context7 only'
Set-Location $mcpProj
Remove-Item -LiteralPath $localProj -Recurse -Force

# 3u. Every Studio command runs: the placeholders filled in as Studio would,
#     each against this checkout.
$studioProj = Join-Path $work 'studio-project'
New-Item -ItemType Directory -Force -Path (Join-Path $studioProj '.git') | Out-Null
Set-Location $studioProj
$studioMeta = [System.IO.File]::ReadAllText((Join-Path $Source '.studio/studio-meta-data.json')) | ConvertFrom-Json
# Each input gets its Studio default: the default choices, or the default text.
$studioValues = @{ guidelinesBranch = 'v3' }
foreach ($inp in $studioMeta.'install-flow'.steps.inputs) {
    $studioValues[$inp.id] = if ($inp.type -eq 'options') {
        @($inp.choices | Where-Object { $_.default } | ForEach-Object { $_.value }) -join ','
    } else { $inp.default }
}
foreach ($step in $studioMeta.'install-flow'.steps) {
    $cmd = $step.command.windows
    $argText = $cmd.Substring($cmd.IndexOf('.Content)) ') + '.Content)) '.Length)
    foreach ($k in $studioValues.Keys) { $argText = $argText.Replace('${' + $k + '}', $studioValues[$k]) }
    Check (-not $argText.Contains('${')) "studio: placeholders filled for the $($step.id) step"
    & $pwshPath -NoProfile -Command "& '$install' $argText -Source '$Source'" *> $null
    Check ($LASTEXITCODE -eq 0) "studio: the $($step.id) command runs"
}
foreach ($f in '.agents/skills', '.claude/skills', 'AGENTS.md', 'CLAUDE.md', '.mcp.json', '.codex/config.toml', 'opencode.json', '.junie/mcp/mcp.json') {
    Check (Test-Path -LiteralPath (Join-Path $studioProj $f)) "studio: the default commands created $f"
}
$keyRegex = ($studioMeta.'install-flow'.steps.inputs | Where-Object { $_.id -eq 'context7Key' }).regex
Check ((@('skip', 'ctx7sk-abcdefgh') | Where-Object { $_ -cmatch $keyRegex }).Count -eq 2 -and
       -not (@('', 'skipx', 'short', 'bad key', 'a"b-cdefgh') | Where-Object { $_ -cmatch $keyRegex })) `
    'studio: the context7Key regex accepts and rejects the right keys'
Set-Location $mcpProj
Remove-Item -LiteralPath $studioProj -Recurse -Force

# 3w. Without a console a missing Context7 key fails that server only: the
#     servers after it are still registered.
$noKeyProj = Join-Path $work 'nokey-project'
New-Item -ItemType Directory -Force -Path (Join-Path $noKeyProj '.git') | Out-Null
Set-Location $noKeyProj
$out = & $pwshPath -NoProfile -NonInteractive -File $install mcp -Servers 'context7,playwright' -Agents opencode 2>&1 | Out-String
Check ($LASTEXITCODE -ne 0) 'mcp: a missing Context7 key fails the run'
Check ($out -match 'Context7 API key is required') 'mcp: a missing Context7 key is reported'
Check ((Test-Path 'opencode.json') -and (Get-Content -Raw 'opencode.json' | ConvertFrom-Json).mcp.playwright) `
    'mcp: Playwright is registered after a missing Context7 key'
Set-Location $mcpProj
Remove-Item -LiteralPath $noKeyProj -Recurse -Force

# 3x. The wizard reads its answers from stdin here. The MCP scope defaults to
#     the skills scope, and an empty Context7 key skips Context7.
$wizProj = Join-Path $work 'wizard-project'
New-Item -ItemType Directory -Force -Path (Join-Path $wizProj '.git') | Out-Null
Set-Location $wizProj
$out = "1`nl`ns`n2,3`n2`n`n`n" | & $pwshPath -NoProfile -File $install -Source $Source 2>&1 | Out-String
Check ($LASTEXITCODE -eq 0) 'wizard exits 0'
Check ($out -match '\[Context7 MCP\] Skipped') 'wizard: an empty key skips Context7'
Check ($out -match 'MCP:\s+context7, playwright for codex \(local\)') 'wizard: the summary names the choices'
Check ((Test-RealDir ".agents/skills/$skill") -and -not (Test-Path '.skills') -and -not (Test-Path '.claude/skills') -and
       -not (Test-Path 'AGENTS.md')) 'wizard: skills and guidelines as chosen'
$toml = Get-Content -Raw '.codex/config.toml'
Check ($toml -match '(?m)^\[mcp_servers\.playwright\]' -and $toml -notmatch 'context7') 'wizard: local Codex config as chosen'
# Global skills make global the default MCP scope.
$ocBefore = if (Test-Path $userOc) { [System.IO.File]::ReadAllBytes($userOc) } else { $null }
$out = "1`ng`ns`n3`n3`n`n" | & $pwshPath -NoProfile -File $install -Source $Source 2>&1 | Out-String
Check ($LASTEXITCODE -eq 0 -and (Test-Path $userOc) -and (Get-Content -Raw $userOc | ConvertFrom-Json).mcp.playwright -and
       -not (Test-Path 'opencode.json')) 'wizard: the MCP scope defaults to the global skills scope'
if ($null -eq $ocBefore) { Remove-Item -LiteralPath $userOc -Force } else { [System.IO.File]::WriteAllBytes($userOc, $ocBefore) }
Set-Location $mcpProj
Remove-Item -LiteralPath $wizProj -Recurse -Force

# 3v. Checking a read-only project config never stages the Context7 key there.
New-Item -ItemType Directory -Force -Path $projCodexDir | Out-Null
Set-TestFile $projCodex "[mcp_servers.context7]`nurl = `"https://mcp.context7.com/mcp`"`n"
$projBefore = Get-Sha $projCodex
if (-not $onWindows) { & chmod 555 $projCodexDir }
$r = Invoke-InstallerResult @('mcp-context7', '-Scope', 'global', '-Agents', 'codex', '-Context7Key', 'ctx7sk-TESTKEY')
if (-not $onWindows) { & chmod 755 $projCodexDir }
Check ($r.Code -eq 0) 'mcp-context7: a matching project config needs no write permission'
Check ((Get-Sha $projCodex) -eq $projBefore) 'mcp-context7: the project config is unchanged'
Check (-not (Get-ChildItem -LiteralPath $mcpProj -Recurse -File -Force | Select-String -SimpleMatch 'TESTKEY' -List)) `
    'mcp-context7: no key or staged file left in the project'
Remove-Item -LiteralPath $projCodexDir -Recurse -Force

$env:PATH = $origPath
Set-Location $proj

# ---------------------------------------------------------------------------
# 4. Negative cases
# ---------------------------------------------------------------------------
Check ((Invoke-Installer @('agents-md', '-Source', $Source)) -ne 0) `
    'negative: agents-md without -Conventions fails'
Check ((Invoke-Installer @('skills', '-Conventions', 'bogus', '-Scope', 'local', '-Source', $Source)) -ne 0) `
    'negative: unknown convention fails'
Check ((Invoke-Installer @('skills', '-Agents', 'claude-desktop', '-Scope', 'local', '-Source', $Source)) -ne 0) `
    'negative: skills rejects claude-desktop'
Check ((Invoke-Installer @('agents-md', '-Agents', 'claude-desktop', '-Source', $Source)) -ne 0) `
    'negative: agents-md rejects claude-desktop'
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
