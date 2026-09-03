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
# 1. agents-md (project guidelines block)
# ---------------------------------------------------------------------------
$blockPath  = Join-Path $Source 'content/guidelines-block.md'
$blockText  = [System.IO.File]::ReadAllText($blockPath)
$beginMark  = '<!-- BEGIN jmix-agent-toolkit -->'
$endMark    = '<!-- END jmix-agent-toolkit -->'
$claudeMd   = Join-Path $proj 'CLAUDE.md'

# 1a. No guidelines file yet -> the file is created holding exactly the block.
Check ((Invoke-Installer @('agents-md', '-Agents', 'claude,codex,opencode,junie', '-Source', $Source)) -eq 0) `
    'agents-md exits 0'
Check (Test-Path $claudeMd)                                'agents-md: CLAUDE.md'
Check (Test-Path (Join-Path $proj 'AGENTS.md'))            'agents-md: AGENTS.md'
Check (Test-Path (Join-Path $proj '.junie/guidelines.md')) 'agents-md: .junie/guidelines.md'
Check (([System.IO.File]::ReadAllText($claudeMd)) -eq $blockText) `
    'agents-md: fresh CLAUDE.md is exactly the block'

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

$agentsMd = Join-Path $proj 'AGENTS.md'
function Reset-Guidelines {
    foreach ($f in @($claudeMd, $agentsMd)) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
    }
    Get-ChildItem -Path $proj -Filter 'CLAUDE.md.bak*' | Remove-Item -Force
    Get-ChildItem -Path $proj -Filter 'AGENTS.md.bak*' | Remove-Item -Force
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

# Reset so later sections start from a clean project guidelines state.
Reset-Guidelines

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

# Studio can pin a feature branch independently of the release default.
Check ((Invoke-Installer @('skills', '-ContentRef', 'no-agents-md-test', '-Agents', 'claude',
        '-Scope', 'global', '-Source', $Source)) -eq 0) `
    'skills(global): content-ref override exits 0'
Check (Test-Path (Join-Path $homeDir '.agents/.jmix/skills/no-agents-md-test')) `
    'skills(global): content-ref override keys the store'

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
