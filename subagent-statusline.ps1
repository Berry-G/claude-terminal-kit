# Side channel that tells statusline.ps1 whether subagents / background work
# are running, so the bongo cat can switch to rage mode.
#
# The main statusLine payload has no field for subagent or background activity,
# but `subagentStatusLine` does: Claude Code runs this once per refresh tick
# while the agent panel has rows, handing it a `tasks` array. So this script
# writes a marker file and prints nothing -- emitting no lines leaves every row
# rendering exactly as Claude Code would have rendered it, and the panel is
# untouched.
#
# Registered in settings.json as:
#   "subagentStatusLine": { "type": "command", "command": "pwsh ... -File ...\\subagent-statusline.ps1" }

$ErrorActionPreference = 'SilentlyContinue'

# UTF-8 stdin, not [Console]::In -- same CP949 mis-decode that broke
# statusline.ps1 applies here, and task names/descriptions are often Korean.
$reader = New-Object System.IO.StreamReader(
    [Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding $false))
$raw = $reader.ReadToEnd()

$j = $null
try { $j = $raw | ConvertFrom-Json } catch {}

# Anything not in a terminal state counts as active. Matching the terminal set
# rather than the running set is the safer direction: an unfamiliar status value
# reads as "still working" instead of silently cancelling rage mode.
$active = 0
foreach ($t in @($j.tasks)) {
    if (-not $t) { continue }
    if ("$($t.status)" -notmatch '^(completed?|done|success|failed|error|cancell?ed|stopped|aborted)$') { $active++ }
}

$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$payload = "$active|$now"

# .NET write, guarded: this runs once per refresh tick alongside the status line
# itself, so it follows the same no-cmdlets rule, and a locked file must not turn
# into an error surfaced against the agent panel.
function Write-Marker {
    param([string]$Path)
    try {
        $tmp = "$Path.$PID.tmp"
        [IO.File]::WriteAllText($tmp, $payload)
        [IO.File]::Move($tmp, $Path, $true)
    } catch { try { [IO.File]::WriteAllText($Path, $payload) } catch {} }
}

# Two keys. The session key is the precise one, but it depends on this payload's
# session_id being the same id the main status line sees -- and a check of %TEMP%
# during a live subagent run found no marker under either the session id or the
# 'default' fallback, while every other per-session file was present. So the
# working directory supplies a second, independent key: it is the same for the
# subagent panel and the status line of the window that owns it, and it is
# narrower than a machine-wide marker, which would put every window into rage
# mode whenever any one of them spawned a subagent.
$id = if ($j.session_id) { "$($j.session_id)" -replace '[^A-Za-z0-9_-]', '' } else { 'default' }
Write-Marker "$env:TEMP\cc-subagents-$id.txt"

$cwd = if ($j.cwd) { "$($j.cwd)" } else { '' }
if ($cwd) {
    $proj = [IO.Path]::GetFileName($cwd.TrimEnd('\', '/'))
    if (-not $proj) { $proj = $cwd -replace '[:\\/\s]', '' }
    $proj = $proj -replace '[^A-Za-z0-9_-]', ''
    if ($proj) { Write-Marker "$env:TEMP\cc-subagents-proj-$proj.txt" }
}

# No stdout: keep Claude Code's default subagent rows.
