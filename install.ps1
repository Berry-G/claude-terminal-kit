<#
.SYNOPSIS
    Install the Claude Code terminal kit (project color coding + status line).

.DESCRIPTION
    Copies the scripts into %USERPROFILE%\.claude, stamps this machine's paths
    into Claude Code's settings.json, and adds a `cc` shortcut to the PowerShell
    profile. Everything it touches is merged, not overwritten, and backed up.

    Run it again any time to update -- it is idempotent.

.EXAMPLE
    .\install.ps1
    Install with auto-detected project root, no profiles generated yet.

.EXAMPLE
    .\install.ps1 -Root G:\Project -Recent 12
    Install and immediately create Windows Terminal profiles for the 12 most
    recently used projects.

.EXAMPLE
    .\install.ps1 -TitleHook
    Also install the hook that prefixes the project name to the window title.

.EXAMPLE
    .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    # Folder that holds the project folders (e.g. G:\Project). Auto-detected
    # when omitted -- see Get-CCRoot in cc-palette.ps1 for the probe order.
    [string]$Root,

    # Also generate Windows Terminal profiles for the N most recent projects
    [int]$Recent = 0,

    # Install the SessionStart/Stop hook that prefixes the project name to the
    # terminal title. Optional: the status line already identifies the project.
    [switch]$TitleHook,

    # Skip adding the `cc` function to the PowerShell profile
    [switch]$NoAlias,

    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$claudeDir = Join-Path $env:USERPROFILE '.claude'
$toolsDir = Join-Path $claudeDir 'tools'
$hooksDir = Join-Path $claudeDir 'hooks'
$settingsPath = Join-Path $claudeDir 'settings.json'
$statusPath = Join-Path $claudeDir 'statusline.ps1'
$subPath = Join-Path $claudeDir 'subagent-statusline.ps1'
$hookPath = Join-Path $hooksDir 'set-terminal-title.ps1'
$aliasMark = '# claude-terminal-kit'

function Say($msg, $color = 'Gray') { Write-Host "  $msg" -ForegroundColor $color }
function Backup($path) {
    if (Test-Path $path) {
        $b = "$path.bak"
        Copy-Item $path $b -Force
        return $b
    }
}

# ---- preflight ----------------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7+ required (running $($PSVersionTable.PSVersion)). Install it with: winget install Microsoft.PowerShell"
}
if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    throw 'pwsh.exe is not on PATH. Install PowerShell 7: winget install Microsoft.PowerShell'
}

Write-Host "`nclaude-terminal-kit" -ForegroundColor Cyan

# ---- uninstall ----------------------------------------------------------------
if ($Uninstall) {
    # generated Windows Terminal profiles
    $gen = Join-Path $toolsDir 'New-CCProfiles.ps1'
    if (Test-Path $gen) {
        try { & $gen -Clean | Out-Null; Say 'removed generated Windows Terminal profiles' } catch { Say "profile cleanup skipped: $_" 'Yellow' }
    }
    # statusLine + hook entries out of settings.json
    if (Test-Path $settingsPath) {
        Backup $settingsPath | Out-Null
        $s = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in 'statusLine', 'subagentStatusLine') {
            if ($s.PSObject.Properties.Name -contains $k) {
                $s.PSObject.Properties.Remove($k); Say "removed $k from settings.json"
            }
        }
        if ($s.hooks) {
            foreach ($evt in @('SessionStart', 'Stop')) {
                if ($s.hooks.PSObject.Properties.Name -contains $evt) {
                    $kept = @($s.hooks.$evt | Where-Object {
                            ($_ | ConvertTo-Json -Depth 10 -Compress) -notmatch 'set-terminal-title'
                        })
                    if ($kept.Count) { $s.hooks.$evt = $kept } else { $s.hooks.PSObject.Properties.Remove($evt) }
                }
            }
            Say 'removed title hook entries'
        }
        ($s | ConvertTo-Json -Depth 100) | Set-Content $settingsPath -Encoding UTF8
    }
    # PowerShell profile alias
    if (Test-Path $PROFILE) {
        $lines = @(Get-Content $PROFILE | Where-Object { $_ -notmatch [regex]::Escape($aliasMark) -and $_ -notmatch 'claude-terminal-kit|tools\\cc\.ps1' })
        Set-Content $PROFILE -Value $lines -Encoding UTF8
        Say 'removed cc alias from PowerShell profile'
    }
    # files (color map stays: it is user data)
    foreach ($f in @($statusPath, $subPath, (Join-Path $claudeDir 'cc-palette.ps1'),
            (Join-Path $claudeDir 'bongocat.ps1'), (Join-Path $claudeDir 'cc-config.json'),
            (Join-Path $toolsDir 'cc.ps1'), (Join-Path $toolsDir 'New-CCProfiles.ps1'), $hookPath)) {
        if (Test-Path $f) { Remove-Item $f -Force }
    }
    Say 'removed scripts'

    # per-session scratch files: colour claims, latched gauges, token offsets,
    # cached rows. All rebuildable, but leaving them behind means a reinstall
    # starts from another machine's state.
    Get-ChildItem "$env:TEMP\cc-*" -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    Say 'removed runtime state from %TEMP%'
    Write-Host "Uninstalled. Color assignments kept at $claudeDir\cc-colors.json`n" -ForegroundColor Green
    return
}

# ---- files --------------------------------------------------------------------
foreach ($d in @($claudeDir, $toolsDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
# statusline.ps1 dot-sources cc-palette.ps1 and bongocat.ps1 from its own
# directory, and reads a marker that subagent-statusline.ps1 writes. All four
# have to land together or the status line dies on the first dot-source.
foreach ($f in 'statusline.ps1', 'cc-palette.ps1', 'bongocat.ps1', 'subagent-statusline.ps1') {
    $from = Join-Path $src $f
    if (-not (Test-Path $from)) { throw "kit is incomplete: $f is missing from $src" }
    Copy-Item $from (Join-Path $claudeDir $f) -Force
}
Copy-Item (Join-Path $src 'tools\cc.ps1')    (Join-Path $toolsDir 'cc.ps1') -Force
Copy-Item (Join-Path $src 'tools\New-CCProfiles.ps1') (Join-Path $toolsDir 'New-CCProfiles.ps1') -Force
Say "scripts -> $claudeDir" 'Green'

# ---- project root -------------------------------------------------------------
. (Join-Path $claudeDir 'cc-palette.ps1')
if (-not $Root) { $Root = Get-CCRoot }
if ($Root -and (Test-Path $Root)) {
    ([pscustomobject]@{ root = $Root } | ConvertTo-Json) |
        Set-Content (Join-Path $claudeDir 'cc-config.json') -Encoding UTF8
    Say "project root -> $Root" 'Green'
} else {
    Say "project root not detected -- set it later: .\install.ps1 -Root <path>" 'Yellow'
}

# ---- settings.json ------------------------------------------------------------
$s = if (Test-Path $settingsPath) {
    Backup $settingsPath | Out-Null
    Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else { [pscustomobject]@{} }

# absolute path: Claude Code runs this through a shell that may not expand %VARS%
#
# refreshInterval keeps the animation alive while the session is idle, and 3 is
# not arbitrary: a render costs ~650ms (pwsh startup and the first console access
# alone are ~580ms of that), and Claude Code cancels a run that is still going
# when the next trigger arrives -- a cancelled run prints nothing, so too short
# an interval makes the whole row flicker in and out.
$statusLine = [pscustomobject]@{
    type            = 'command'
    command         = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$statusPath`""
    padding         = 0
    refreshInterval = 3
}
if ($s.PSObject.Properties.Name -contains 'statusLine') { $s.statusLine = $statusLine }
else { $s | Add-Member -NotePropertyName statusLine -NotePropertyValue $statusLine }

# The main statusLine payload carries nothing about subagents, so this second
# hook is the only way the cat can know background work is running. It writes a
# marker file and prints nothing, which leaves Claude Code's own subagent rows
# exactly as they were.
$subLine = [pscustomobject]@{
    type    = 'command'
    command = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$subPath`""
}
if ($s.PSObject.Properties.Name -contains 'subagentStatusLine') { $s.subagentStatusLine = $subLine }
else { $s | Add-Member -NotePropertyName subagentStatusLine -NotePropertyValue $subLine }
Say 'settings.json: statusLine + subagentStatusLine registered' 'Green'

if ($TitleHook) {
    if (-not (Test-Path $hooksDir)) { New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null }
    Copy-Item (Join-Path $src 'hooks\set-terminal-title.ps1') $hookPath -Force
    if ($s.PSObject.Properties.Name -notcontains 'hooks') {
        $s | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
    }
    $entry = [pscustomobject]@{
        hooks = @([pscustomobject]@{
                type    = 'command'
                command = 'pwsh'
                args    = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $hookPath)
                timeout = 30
                async   = $true
            })
    }
    foreach ($evt in @('SessionStart', 'Stop')) {
        $existing = @()
        if ($s.hooks.PSObject.Properties.Name -contains $evt) {
            # drop any previous copy of ours, keep the user's other hooks
            $existing = @($s.hooks.$evt | Where-Object {
                    ($_ | ConvertTo-Json -Depth 10 -Compress) -notmatch 'set-terminal-title'
                })
            $s.hooks.$evt = @($existing + $entry)
        } else {
            $s.hooks | Add-Member -NotePropertyName $evt -NotePropertyValue @($entry)
        }
    }
    Say 'settings.json: title hook registered' 'Green'
}

($s | ConvertTo-Json -Depth 100) | Set-Content $settingsPath -Encoding UTF8

# ---- PowerShell profile alias -------------------------------------------------
if (-not $NoAlias) {
    $profileDir = Split-Path -Parent $PROFILE
    if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
    $existing = if (Test-Path $PROFILE) { Get-Content $PROFILE -Raw } else { '' }
    if ($existing -notmatch [regex]::Escape($aliasMark)) {
        Add-Content $PROFILE -Value @"

$aliasMark -- open a color-coded Claude Code tab:  cc <project>  /  cc  to list
function cc { & "`$env:USERPROFILE\.claude\tools\cc.ps1" @args }
"@ -Encoding UTF8
        Say "cc alias -> $PROFILE" 'Green'
    } else {
        Say 'cc alias already present'
    }
}

# ---- smoke test ---------------------------------------------------------------
# Registering the status line is not the same as it working. Feed the real thing
# a representative payload and check what comes back, so a broken install fails
# here rather than silently showing an empty row later.
$probe = [pscustomobject]@{
    session_id     = 'kit-install-probe'
    prompt_id      = 'probe'
    model          = @{ display_name = 'Probe' }
    workspace      = @{ project_dir = $claudeDir; current_dir = $claudeDir }
    cost           = @{ total_api_duration_ms = 1; total_cost_usd = 0; total_lines_added = 0; total_lines_removed = 0 }
    context_window = @{ used_percentage = 42 }
} | ConvertTo-Json -Depth 10 -Compress

$probeFile = Join-Path ([IO.Path]::GetTempPath()) 'cc-install-probe.json'
[IO.File]::WriteAllBytes($probeFile, [Text.Encoding]::UTF8.GetBytes($probe))
$out = ''
try {
    $out = (Get-Content $probeFile -Raw | pwsh -NoProfile -ExecutionPolicy Bypass -File $statusPath) -join "`n"
} catch { }
Remove-Item $probeFile -Force -ErrorAction SilentlyContinue
Get-ChildItem "$env:TEMP\cc-*kit-install-probe*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

$esc = [char]27
$plain = $out -replace "$esc\[[0-9;]*m", ''
if (-not $plain.Trim()) {
    throw "status line produced no output. Run it by hand to see the error:`n  '$probe' | pwsh -NoProfile -File `"$statusPath`""
}
if ($plain -notmatch '42') {
    Say "status line rendered but the context gauge is missing -- check $statusPath" 'Yellow'
}
if ($out -notmatch [regex]::Escape($esc)) {
    Say 'status line rendered without colour. Your terminal may strip ANSI.' 'Yellow'
}
Say 'smoke test passed' 'Green'
Say ("  " + (($plain -split "`n")[0]).Trim())

# ---- optional: generate profiles now ------------------------------------------
if ($Recent -gt 0) {
    & (Join-Path $toolsDir 'New-CCProfiles.ps1') -Recent $Recent
}

Write-Host "`nDone. Restart Claude Code sessions to pick up the status line." -ForegroundColor Cyan
Write-Host "  (settings.json is read at session start -- an open session will not change)" -ForegroundColor DarkGray
Write-Host "Next:  . `$PROFILE   then   cc            (list projects)" -ForegroundColor Cyan
Write-Host "       ~\.claude\tools\New-CCProfiles.ps1 -Recent 12`n" -ForegroundColor Cyan
