# Claude Code statusLine: shows the project name as a colored block at the
# bottom of the session, so the window you are typing into always identifies
# itself -- without competing with the terminal title, which the Stop/SessionStart
# hook uses to signal busy/idle state.
#
# Registered in settings.json as:
#   "statusLine": { "type": "command", "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File C:\\Users\\website\\.claude\\statusline.ps1" }

$ErrorActionPreference = 'SilentlyContinue'
# This script is on a hot path: Claude Code re-runs it every refreshInterval
# tick, and cancels a run still in flight when the next trigger arrives -- a
# cancelled run prints nothing, which is why a slow status line flickers in and
# out. So prefer .NET calls over cmdlets throughout, and never set
# [Console]::OutputEncoding: assigning it reinitialises the console and cost
# 240ms of a ~1s budget on its own. Output goes out as raw UTF-8 bytes instead,
# which needs no console encoding at all.

# --- output and last-resort recovery, established before anything else --------
# A trap is registered for the whole script scope no matter where it is written,
# so it fires for errors raised above its own position too. When the emit
# machinery lived further down, an early terminating error hit a trap whose body
# called an as-yet-undefined Emit against a $null $stdout -- the failure was
# swallowed by Emit's own catch and the process exited 0 having written nothing,
# producing exactly the blank row the trap exists to prevent. Everything the
# trap touches is therefore set up here, before the first statement that can
# throw, and each piece is null-checked because an error can still arrive before
# the later ones are filled in.
$stdout = [Console]::OpenStandardOutput()
function Emit {
    param([string]$Text)
    if (-not $Text) { return }
    try {
        $b = [Text.Encoding]::UTF8.GetBytes($Text)
        $stdout.Write($b, 0, $b.Length)
        $stdout.Flush()
    } catch {}
}

$block = $null          # nameplate, once the project colour is resolved
$blockEmitted = $false
$linePath = $null       # per-session cache of everything after the nameplate

function Write-CCFile {
    # Every file this script writes is read by another process -- another window,
    # or this window's next render. WriteAllText truncates first and then writes,
    # so a concurrent reader can catch the file empty or half-filled; for the
    # line cache that means either a sharing violation (row renders with every
    # field dropped) or a prefix ending inside an ANSI escape, which the terminal
    # swallows and then bleeds colour across the rest of the row. Building beside
    # the target and moving it into place makes the swap atomic on NTFS, so a
    # reader sees either the whole old file or the whole new one.
    param([string]$Path, [string]$Text)
    try {
        $tmp = "$Path.$PID.tmp"
        [IO.File]::WriteAllText($tmp, $Text)
        [IO.File]::Move($tmp, $Path, $true)
    } catch {
        # Last resort if the temp file cannot be created (full disk, denied
        # permissions): a direct write is still better than no state at all.
        try { [IO.File]::WriteAllText($Path, $Text) } catch {}
    }
}

trap {
    # Salvage as much of the row as exists. The nameplate goes first if it was
    # built but not yet flushed; the cached tail follows if this window has one.
    if (-not $blockEmitted -and $block) { Emit $block }
    $t = ''
    if ($linePath -and [IO.File]::Exists($linePath)) {
        try { $t = [IO.File]::ReadAllText($linePath) } catch {}
    }
    Emit ($t + [Environment]::NewLine)
    exit 0
}

. (Join-Path $PSScriptRoot 'cc-palette.ps1')
. (Join-Path $PSScriptRoot 'bongocat.ps1')

# Read stdin as UTF-8 explicitly. [Console]::In decodes using the console's
# input code page, which is CP949 here, and Claude Code sends UTF-8 JSON. That
# only bites once the payload carries non-ASCII: an AI-generated Korean
# session_name mis-decodes such that a lead byte swallows the closing quote,
# the JSON no longer parses, and every field silently goes missing.
$reader = New-Object System.IO.StreamReader(
    [Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding $false))
$raw = $reader.ReadToEnd()

$j = $null
try { $j = $raw | ConvertFrom-Json } catch {}

$root = $j.workspace.project_dir
$cur = $j.workspace.current_dir
if (-not $root) { $root = $cur }
if (-not $root) { $root = [IO.Directory]::GetCurrentDirectory() }
if (-not $cur) { $cur = $root }

# GetFileName of a trimmed drive root ("D:\" -> "D:") is the empty string, which
# would blank the one field that must never blank. Fall back to the bare drive
# letter, then to a fixed name, so the nameplate always has something to show.
$proj = [IO.Path]::GetFileName($root.TrimEnd('\', '/'))
if (-not $proj) { $proj = $root -replace '[:\\/\s]', '' }
if (-not $proj) { $proj = 'claude' }

function Resolve-CCLiveColor {
    # A hash cannot avoid collisions it cannot see. Get-CCColorIndex picks a
    # palette slot from one MD5 byte mod 16, so any two project names can land
    # on the same colour -- three projects open at the time all hash to slot 3,
    # which is why three windows were all lime. With five projects in sixteen
    # slots a collision is more likely than not.
    #
    # So the colour is negotiated against the windows that are actually open.
    # Each render re-stakes this project's claim in a shared registry; a claim
    # goes stale after 30s (ten missed heartbeats at refreshInterval 3), which is
    # how a closed window releases its colour.
    # Contested slots go to whoever staked them FIRST. That needs two separate
    # timestamps per claim: `seen` is refreshed every render and is what expiry
    # is measured from, while `since` records when the colour was first taken and
    # never moves. Heartbeating a single timestamp would erase exactly the
    # ordering the tie-break depends on.
    #   line format: project|hex|seenMs|sinceMs
    param([string]$Project, [string]$Preferred)

    $path = "$env:TEMP\cc-colors-live.txt"
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $mine = $Project.ToLower()

    $readClaims = {
        $h = @{}
        if ([IO.File]::Exists($path)) {
            foreach ($l in [IO.File]::ReadAllLines($path)) {
                $f = $l -split '\|'
                if ($f.Count -lt 4) { continue }
                # Parse per line and skip what will not parse. Letting a cast
                # throw here took the whole function out through the caller's
                # catch -- and since the only code that rewrites this file sits
                # downstream of the throw, a single corrupt line meant no window
                # ever repaired it. Colour negotiation stayed dead permanently
                # and every colliding project went back to sharing one colour.
                # Skipping instead means the row is dropped and the rewrite at
                # the end of this function cleans the file up.
                $seen = 0L; $since = 0L
                if (-not [long]::TryParse($f[2], [ref]$seen)) { continue }
                if (-not [long]::TryParse($f[3], [ref]$since)) { continue }
                if ("$($f[1])" -notmatch '^#[0-9A-Fa-f]{6}$') { continue }
                if (($now - $seen) -gt 30000) { continue }
                $h[$f[0]] = @{ Hex = $f[1]; Seen = $seen; Since = $since }
            }
        }
        $h
    }

    $pickFree = {
        param($taken)
        if (-not $taken.ContainsKey($Preferred)) { return $Preferred }
        # Walk forward from the preferred slot so the fallback stays
        # deterministic; settle for the preferred colour only if every slot is
        # spoken for.
        $start = [array]::IndexOf($CCPalette, $Preferred)
        if ($start -lt 0) { $start = 0 }
        for ($i = 1; $i -le $CCPalette.Count; $i++) {
            $cand = $CCPalette[($start + $i) % $CCPalette.Count]
            if (-not $taken.ContainsKey($cand)) { return $cand }
        }
        $Preferred
    }

    $claims = & $readClaims
    if ($claims.ContainsKey($mine)) {
        # Already holding one -- keep it, so a window's colour never shifts under
        # it while it is open. Two windows on the same project share a claim and
        # therefore share a colour, which is the point of a project colour.
        $hex = $claims[$mine].Hex
        $since = $claims[$mine].Since
    } else {
        $taken = @{}
        foreach ($k in $claims.Keys) { if ($k -ne $mine) { $taken[$claims[$k].Hex] = $true } }
        $hex = & $pickFree $taken
        $since = $now
    }

    # Re-read and write under a named mutex, because this is a read-modify-write
    # of the whole file. File.Move makes the swap atomic for readers, but that
    # only guarantees a reader never sees a half-written file -- it does nothing
    # about two windows each rebuilding the file from its own stale snapshot,
    # where the second write silently erases the first window's row. The victim
    # then finds no claim of its own next tick, picks a fresh colour, and the
    # nameplate changes colour mid-session: exactly the instability this function
    # exists to prevent.
    #
    # Local\ rather than Global\ -- every window runs as the same user in the
    # same session, and Global\ needs privileges that would make the mutex fail
    # to open. A bounded wait keeps the render inside its latency budget: if the
    # lock cannot be had quickly, this window renders the colour it already
    # computed and re-stakes its claim on the next tick rather than blocking.
    $mutex = $null
    $gotLock = $false
    try {
        $mutex = New-Object System.Threading.Mutex($false, 'Local\cc-statusline-colors')
        try { $gotLock = $mutex.WaitOne(150) }
        catch [System.Threading.AbandonedMutexException] {
            # A window died holding the lock. The mutex is ours regardless, and
            # the file it left behind is whole -- File.Move saw to that.
            $gotLock = $true
        }

        if ($gotLock) {
            # Check-and-set: re-read immediately before writing, and stand down
            # if an earlier claim on this colour appeared in the meantime.
            # Yielding to the older claim rather than overwriting it is what
            # makes the later writer lose.
            $fresh = & $readClaims
            for ($attempt = 0; $attempt -lt 3; $attempt++) {
                $mustYield = $false
                foreach ($k in $fresh.Keys) {
                    if ($k -eq $mine -or $fresh[$k].Hex -ne $hex) { continue }
                    # Identical instants are broken by name so both sides reach
                    # the same verdict instead of trading the colour back and
                    # forth.
                    if ($fresh[$k].Since -lt $since -or ($fresh[$k].Since -eq $since -and $k -lt $mine)) {
                        $mustYield = $true
                        break
                    }
                }
                if (-not $mustYield) { break }

                $taken = @{}
                foreach ($k in $fresh.Keys) { if ($k -ne $mine) { $taken[$fresh[$k].Hex] = $true } }
                $hex = & $pickFree $taken
                $since = $now
            }

            try {
                # Other windows' rows are copied through untouched. Refreshing
                # their `seen` here would keep closed windows alive forever,
                # since nothing else ever ages them out.
                $lines = @("$mine|$hex|$now|$since")
                foreach ($k in $fresh.Keys) {
                    if ($k -eq $mine) { continue }
                    $lines += "$k|$($fresh[$k].Hex)|$($fresh[$k].Seen)|$($fresh[$k].Since)"
                }
                $tmp = "$path.$PID.tmp"
                [IO.File]::WriteAllLines($tmp, [string[]]$lines)
                [IO.File]::Move($tmp, $path, $true)
            } catch {}
        }
    } finally {
        if ($gotLock) { try { $mutex.ReleaseMutex() } catch {} }
        if ($mutex) { $mutex.Dispose() }
    }

    $hex
}

# Neither colour source is trustworthy input. cc-colors.json is written by an
# unrelated script and cc-colors-live.txt is shared mutable state, so either can
# hand back a shorthand "#FFF", a colour name, or an empty string -- and
# ConvertFrom-CCHex does a bare Substring/ToInt32, which throws on all of them.
# That throw lands before the nameplate is emitted and repeats every tick, so it
# is validated here rather than trusted.
$hexOk = { param($v) "$v" -match '^#[0-9A-Fa-f]{6}$' }

$hex = Get-CCColor $proj
if (-not (& $hexOk $hex)) { $hex = $CCPalette[(Get-CCColorIndex $proj)] }
try { $hex = Resolve-CCLiveColor -Project $proj -Preferred $hex } catch {}
if (-not (& $hexOk $hex)) { $hex = $CCPalette[(Get-CCColorIndex $proj)] }

$c = $null
try { $c = ConvertFrom-CCHex $hex } catch {}
# Belt and braces: the palette itself is a literal in cc-palette.ps1, so this
# only fires if that file is edited into an invalid state.
if ($null -eq $c) { $c = [pscustomobject]@{ R = 140; G = 155; B = 165 } }
# relative luminance -> black or white text on the colored block
$lum = (0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B)
$plateFg = if ($lum -gt 150) { '0;0;0' } else { '255;255;255' }

$e = [char]27
$block = "$e[48;2;$($c.R);$($c.G);$($c.B)m$e[38;2;${plateFg}m$e[1m $($proj.ToUpper()) $e[0m"
$dim = "$e[2m"
$tint = "$e[38;2;$($c.R);$($c.G);$($c.B)m"
$off = "$e[0m"
# Plain terminal foreground -- no colour of its own, so it matches whatever the
# prompt input text is. Used for the structural pieces (meter labels, field
# separators) that should read as part of the frame rather than as data.
$fg = "$e[0m"

# --- emit the nameplate immediately ------------------------------------------
# Claude Code cancels a run still in flight when the next update triggers, and a
# cancelled run that has printed nothing leaves the row blank. The project name
# is the one field that must never vanish, so it is computed from the cheapest
# inputs available (the payload and the colour map, nothing else) and pushed out
# and flushed before any of the slower work starts. Whatever happens after this
# point, these bytes have already left the process.
Emit $block
$blockEmitted = $true

# Everything after the nameplate is cached, so a run that fails partway can fall
# back to the previous render rather than dropping fields. Stale gauges beat
# missing gauges.
#
# Keyed by session and nothing else. A project-keyed cache used to back this up
# for the case where the payload will not parse and the session id is therefore
# unknown -- but every window on a project shares that key, so the fallback could
# restore another window's tail and show its cost, tokens, model and branch under
# this window's nameplate with nothing marking them foreign. Fewer fields is
# recoverable; correct-looking numbers belonging to a different session are not.
# The nameplate, which is the actual hard requirement, is already out either way.
#
# Derived once and reused for every per-session file below. Computing it twice
# invites the cache key and the state key to drift apart if only one is edited.
$sid = if ($j.session_id) { "$($j.session_id)" -replace '[^A-Za-z0-9_-]', '' } else { 'default' }
$linePath = "$env:TEMP\cc-line-$sid.txt"

$parts = @()

# path: full project dir, plus the sub-path when cd'd deeper
$sub = ''
if ($cur -and $cur.Length -gt $root.Length -and $cur.StartsWith($root, 'OrdinalIgnoreCase')) {
    $sub = $cur.Substring($root.Length).TrimStart('\', '/')
}
$pathText = $root
if ($sub) { $pathText = "$root$tint\$sub$off$dim" }
# Appended last, not here. Claude Code truncates an over-wide status line from
# the right with an ellipsis, and the gauges are graphics -- a bar clipped
# mid-fill misreads as a different value, whereas a shortened path is still a
# path. Putting the text last means the path absorbs the truncation.
$pathPart = "$dim$pathText$off"

# Busy/idle state, used twice: it animates the bongo cat on row two, and it
# marks the "command finished" edge that resamples the gauges below.
$st = Get-BongoState -SessionId $j.session_id -ApiMs ([double]$j.cost.total_api_duration_ms)

# --- usage gauges -----------------------------------------------------------
# Values are sampled at exactly two moments and held steady in between:
#   command submitted -> prompt_id changes to a new UUID
#   command finished  -> the busy heuristic falls back to idle
# Everything the gauges need arrives on the statusLine payload, and a payload
# arrives every refreshInterval tick, so without this the numbers would drift
# continuously. Latching them means the bar you read after a command is the
# reading for that command, not a mid-flight sample. Detection has to live here
# rather than in a UserPromptSubmit/Stop hook: hook input carries session_id and
# cwd but no rate_limits or context_window, so hooks cannot supply the numbers.
#
# Scope differs per meter, so the state is split across two files:
#   CTX     is this conversation's own context -- per-session file.
#   5H / 7D are account-wide quotas that every window draws from -- one shared
#           file, so all open windows agree. Any window that reaches a sample
#           point publishes the reading, and every window renders the newest
#           one. That means an idle window's quota bars still move when another
#           window is working, which is the whole point of syncing them.
$usagePath = "$env:TEMP\cc-usage-$sid.txt"
$sharedPath = "$env:TEMP\cc-usage-shared.txt"

function Read-Num($v) { if ($null -ne $v) { [double]$v } else { -1.0 } }

$liveCtx = Read-Num $j.context_window.used_percentage
$liveFive = Read-Num $j.rate_limits.five_hour.used_percentage
$liveSeven = Read-Num $j.rate_limits.seven_day.used_percentage
# Reset instants are absolute epoch seconds, so they travel between windows
# unchanged -- no clock arithmetic needed before publishing them.
$liveFiveAt = Read-Num $j.rate_limits.five_hour.resets_at
$liveSevenAt = Read-Num $j.rate_limits.seven_day.resets_at
$liveCost = Read-Num $j.cost.total_cost_usd
$liveAdd = Read-Num $j.cost.total_lines_added
$liveDel = Read-Num $j.cost.total_lines_removed

$prevPrompt = ''; $wasBusy = $false; $held = $null
$tokIn = 0.0; $tokOut = 0.0; $offset = 0L
if ([IO.File]::Exists($usagePath)) {
    # The casts live inside the try as well as the read. A half-written or
    # hand-edited state file makes them throw, and an unguarded throw here would
    # take the whole render into the trap and fall back to the cached line --
    # discarding a render that only needed to start from defaults.
    try {
        $f = [IO.File]::ReadAllText($usagePath).Trim() -split '\|'
        if ($f.Count -ge 9) {
            $prevPrompt = $f[0]
            $wasBusy = ($f[1] -eq '1')
            $held = @([double]$f[2], [double]$f[3], [double]$f[4], [double]$f[5])
            $tokIn = [double]$f[6]
            $tokOut = [double]$f[7]
            $offset = [long]$f[8]
        }
    } catch { $held = $null; $tokIn = 0.0; $tokOut = 0.0; $offset = 0L }
}

function Add-TranscriptTokens {
    # Cumulative session tokens are not on the payload -- context_window.* has
    # described the *current* context window rather than session totals since
    # v2.1.132, so it cannot be paired with the cumulative cost. The transcript
    # is the only cumulative source, so tally it here.
    #
    # Only the bytes appended since the last sample are read, so this costs one
    # short read per command instead of re-parsing a growing file every tick.
    param([string]$Path, [long]$From)

    # Reset says "these totals replace what you had", as opposed to the usual
    # "add these to what you had". Without it the caller's += turned a
    # from-zero rescan into a double count that persisted for the session.
    $result = @{ In = 0.0; Out = 0.0; Offset = $From; Reset = $false }
    if (-not $Path -or -not [IO.File]::Exists($Path)) { return $result }

    # Two separate limits, because they bound different things.
    #
    # Nothing bounded this at all before, so a cold offset against a large
    # transcript scanned the whole file -- and since the state write that records
    # progress happens after this call, an over-budget run was cancelled before
    # it could persist an offset, so every tick repeated the entire scan and the
    # row showed nothing but the nameplate for the whole command.
    #
    # The time budget bounds the parse, which is what varies: cost is per line,
    # not per byte, so a byte cap alone swings wildly with line density.
    # Stopping on elapsed time keeps every run inside its slice whatever the file
    # looks like, and the leftover drains on the following ticks.
    #
    # $maxBytes then has to be sized to what the budget can actually chew, not
    # larger: reading, decoding and splitting a chunk costs even for the part
    # never parsed, and a 2MB chunk against a ~400KB budget spent most of each
    # run on setup for lines it then abandoned. Matching the two keeps the
    # per-tick cost flat while draining at the same rate.
    # 80ms, not more: the rest of a render already peaks near 800ms on this
    # machine with no backlog at all, and the whole point is to stay far enough
    # under the 3s refreshInterval that a run is never cancelled mid-scan.
    $maxBytes = 512KB
    $budgetMs = 80

    try {
        # Share write access: Claude Code is appending to this file as we read.
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            # A rewritten or compacted transcript is shorter than where we left
            # off; start over rather than seeking past the end. The result offset
            # has to be reset with it, or a run that finds no complete line would
            # return the old past-the-end offset and never recover.
            if ($fs.Length -lt $From) { $From = 0; $result.Offset = 0; $result.Reset = $true }
            $fs.Seek($From, [IO.SeekOrigin]::Begin) | Out-Null

            # Stream.Read is allowed to return fewer bytes than asked for. Taking
            # a single call's result as the whole delta would undercount tokens
            # while still advancing the offset past the bytes it skipped, so the
            # miss would be permanent. Loop until the stream is drained.
            $len = [int][math]::Min($maxBytes, $fs.Length - $From)
            $buf = New-Object byte[] $len
            $read = 0
            while ($read -lt $len) {
                $n = $fs.Read($buf, $read, $len - $read)
                if ($n -le 0) { break }
                $read += $n
            }
        } finally { $fs.Dispose() }

        $text = [Text.Encoding]::UTF8.GetString($buf, 0, $read)
        # The final line may be half-written; nothing past the last newline is
        # safe to parse, so it is left for the next sample.
        #
        # EVERY string search below is pinned to Ordinal (or the char overload,
        # which is ordinal already). String.IndexOf(string) defaults to
        # CurrentCulture, and under ko-KR that runs the ICU collator over the
        # buffer: measured on 2MB, 3000 newline searches cost 2188ms culture-
        # sensitive against 26ms ordinal, and 200 searches for an absent key cost
        # 9383ms against 29ms. It is invisible on the short strings this code
        # used to search and catastrophic on a multi-megabyte one.
        $lastNl = $text.LastIndexOf([char]10)
        if ($lastNl -lt 0) { return $result }

        # Read = everything fed into the model, cache hits included. Write = what
        # it produced. They are wildly different magnitudes and priced
        # differently, so one combined figure hid more than it showed.
        #
        # Split into lines first, then search each short line -- not IndexOf with
        # a start index into the whole multi-megabyte buffer. Measured on 8000
        # lines: 1033ms searching the buffer against 351ms searching the split
        # lines, three times the throughput for the same result. A whole-buffer
        # regex pass is faster still (197ms) but cannot be used, because the
        # "iterations" array repeats every one of these keys and a buffer-wide
        # count would silently double.
        # Split $text directly rather than copying it up to the last newline
        # first. The final element is either the half-written tail or an empty
        # string, and skipping it covers both, so the copy bought nothing.
        $lines = $text.Split([char]10)
        $ord = [StringComparison]::Ordinal
        $inKeys = @('"input_tokens":', '"cache_creation_input_tokens":', '"cache_read_input_tokens":')
        $outKey = '"output_tokens":'

        $sumIn = 0.0; $sumOut = 0.0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $chars = 0   # characters of $text fully accounted for

        for ($li = 0; $li -lt $lines.Length - 1; $li++) {
            $l = $lines[$li]

            $u = $l.IndexOf('"usage"', $ord)
            if ($u -ge 0) {
                # Stop before "iterations", which repeats the same counts once
                # per API round-trip and would double-count them.
                $stop = $l.IndexOf('"iterations"', $ord)
                if ($stop -lt 0) { $stop = $l.Length }

                foreach ($k in $inKeys) {
                    # The leading quote is what keeps "input_tokens" from also
                    # matching "cache_creation_input_tokens" and friends.
                    $i = $l.IndexOf($k, $ord)
                    if ($i -lt 0 -or $i -ge $stop) { continue }
                    $i += $k.Length
                    $v = 0.0
                    while ($i -lt $stop) {
                        $ch = [int]$l[$i]
                        if ($ch -lt 48 -or $ch -gt 57) { break }
                        $v = $v * 10 + ($ch - 48)
                        $i++
                    }
                    $sumIn += $v
                }

                $i = $l.IndexOf($outKey, $ord)
                if ($i -ge 0 -and $i -lt $stop) {
                    $i += $outKey.Length
                    $v = 0.0
                    while ($i -lt $stop) {
                        $ch = [int]$l[$i]
                        if ($ch -lt 48 -or $ch -gt 57) { break }
                        $v = $v * 10 + ($ch - 48)
                        $i++
                    }
                    $sumOut += $v
                }
            }

            # Advance only over lines actually accounted for, so stopping early
            # leaves the rest for the next tick instead of skipping it. The +1 is
            # the newline Split consumed; a trailing \r stays inside $l.Length.
            $chars += $l.Length + 1
            if (($li -band 127) -eq 127 -and $sw.ElapsedMilliseconds -gt $budgetMs) { break }
        }

        # Byte offset, not char offset: the file is UTF-8 and the transcript
        # carries Korean, so the two differ.
        $result.Offset = $From + [Text.Encoding]::UTF8.GetByteCount($text.Substring(0, $chars))
        $result.In = $sumIn
        $result.Out = $sumOut
    } catch {}
    $result
}

$curPrompt = "$($j.prompt_id)"
# A payload that failed to parse must never count as a sample point. Without the
# $j guard, prompt_id reads as empty, compares unequal to the stored UUID, and
# resamples -- writing a row of -1 live values over the latched cost, context and
# line counts that the next render was going to display.
$resample = $j -and (($null -eq $held) -or ($curPrompt -ne $prevPrompt) -or ($wasBusy -and -not $st.Busy))
# Past this point $held is always indexable, so the render never has to care
# whether a previous state file existed.
if ($null -eq $held) { $held = @(-1.0, -1.0, -1.0, -1.0) }

# Cost and line counts latch on the same beat as the context meter. They are
# cumulative counters that creep during a command, and a figure that only moves
# at command boundaries is one you can actually compare against the last one.
$ctxShown = if ($resample) { $liveCtx } else { $held[0] }
$costShown = if ($resample) { $liveCost } else { $held[1] }
$addShown = if ($resample) { $liveAdd } else { $held[2] }
$delShown = if ($resample) { $liveDel } else { $held[3] }

# Not gated on $resample. A capped scan can leave a backlog, and the backlog has
# to drain on ordinary ticks -- gating it on command boundaries would mean a
# large transcript never catches up while the window sits idle. With no backlog
# this costs one file-length check.
if ($j) {
    $t = Add-TranscriptTokens -Path $j.transcript_path -From $offset
    if ($t.Reset) {
        # The transcript was rewritten and rescanned from the start, so these are
        # totals rather than a delta. Adding them would count everything that
        # survived the rewrite twice, permanently, including after a restart.
        $tokIn = $t.In
        $tokOut = $t.Out
    } else {
        $tokIn += $t.In
        $tokOut += $t.Out
    }
    $offset = $t.Offset
}

# Only a parsed payload may rewrite the state file, for the same reason it may
# not resample: a degraded render has nothing worth persisting, and persisting it
# would destroy what the next good render needs.
if ($j) {
    Write-CCFile $usagePath "$curPrompt|$(if ($st.Busy) { 1 } else { 0 })|$ctxShown|$costShown|$addShown|$delShown|$tokIn|$tokOut|$offset"
}

# Read the shared record first, merge this window's reading into it, and only
# then publish. Publishing before reading let a window overwrite a fresher
# reading with its own stale one: a window that has sat idle still carries the
# rate_limits from its last API call, so the moment it resampled it would push
# that old number over whatever a busy window had just published, and every
# window would show the wrong figure until the busy one worked again.
$fiveShown = -1.0; $sevenShown = -1.0
$fiveAt = -1.0; $sevenAt = -1.0
try {
    if ([IO.File]::Exists($sharedPath)) {
        $sf = [IO.File]::ReadAllText($sharedPath).Trim() -split '\|'
        if ($sf.Count -ge 5) {
            $fiveShown = [double]$sf[0]; $sevenShown = [double]$sf[1]
            $fiveAt = [double]$sf[2]; $sevenAt = [double]$sf[3]
        }
    }
} catch {}

# Which of the two readings is newer, for one quota window:
#   nothing published yet          -> anything beats nothing
#   later resets_at                -> a later reset instant can only come from a
#                                     later observation, and it is also how a
#                                     rolled-over window is detected: a reading
#                                     from the previous window would otherwise
#                                     keep showing 90% after the quota refilled
#   same resets_at, higher usage   -> usage only climbs within a window
$isNewer = {
    param($live, $liveAt, $have, $haveAt)
    if ($live -lt 0) { return $false }
    if ($have -lt 0) { return $true }
    if ($liveAt -gt $haveAt) { return $true }
    ($liveAt -eq $haveAt -and $live -gt $have)
}

$adoptFive = & $isNewer $liveFive $liveFiveAt $fiveShown $fiveAt
$adoptSeven = & $isNewer $liveSeven $liveSevenAt $sevenShown $sevenAt
if ($adoptFive) { $fiveShown = $liveFive; $fiveAt = $liveFiveAt }
if ($adoptSeven) { $sevenShown = $liveSeven; $sevenAt = $liveSevenAt }

# Expire a reading whose own window has ended. "Newer wins" cannot do this on its
# own: an idle window's payload still carries the rate_limits from its last API
# call, so live and published agree exactly and neither replaces the other. The
# reading then sits at, say, 92% for hours after the quota actually refilled --
# and the countdown, being negative, prints nothing, so the bar gives no hint it
# is describing a window that no longer exists. Reading a near-full quota bar and
# deferring work over it is the worst failure this row can produce, so a rolled
# over window is reported as the empty quota it now is. Any real usage produces a
# fresh reading immediately and overwrites this.
$nowSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
if ($fiveAt -gt 0 -and $nowSec -ge $fiveAt) { $fiveShown = 0.0; $fiveAt = -1.0 }
if ($sevenAt -gt 0 -and $nowSec -ge $sevenAt) { $sevenShown = 0.0; $sevenAt = -1.0 }

# Publish only what actually moved the record forward, so the shared state is
# monotonic no matter which window writes it. Several windows can be writing at
# once, so build the file beside the target and move it into place -- File.Move
# is atomic on NTFS, so a reader mid-update sees the whole previous version
# rather than a half-written line.
if ($resample -and ($adoptFive -or $adoptSeven)) {
    Write-CCFile $sharedPath "$fiveShown|$sevenShown|$fiveAt|$sevenAt|$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
}

$shown = @($ctxShown, $fiveShown, $sevenShown)

# The bar is drawn as background-coloured spaces, not fill characters. Every
# candidate fill glyph -- block elements, box drawing, geometric shapes -- is
# East-Asian *ambiguous* width, which is what broke the earlier art on this
# machine. A space is unambiguously one column in every font, so painting its
# background gives a solid bar with no width or glyph-coverage risk at all.
# Every filled cell is the project colour at full strength -- the same value
# behind the uppercase project block, so a window's meters and its nameplate are
# visibly the same window. One flat level, no gradient along the bar: an earlier
# position-based ramp dimmed the leading cells, which made a lightly-filled meter
# read as empty exactly when it was the meter you needed to see.
$CCFill = @($c.R, $c.G, $c.B)

# The channel carries a trace of the project hue over a neutral floor, bright
# enough to be visible at 0% so an empty meter still reads as a meter, dark
# enough that the fill never has to compete with it.
$CCBase = @(38, 42, 50)
$CCTrack = 0, 1, 2 | ForEach-Object { [int][math]::Round($CCBase[$_] + ($CCFill[$_] - $CCBase[$_]) * 0.15) }

function New-CCGauge {
    # 10 cells so one cell is exactly 10% -- the bar and the percentage next to
    # it are then read off the same scale, and every step is a round number.
    param([string]$Label, [double]$Pct, [double]$ResetsAt = -1, [int]$Cells = 10)
    $p = [math]::Max(0.0, [math]::Min(100.0, $Pct))

    # Whole cells only -- exactly two colours in any bar. Partial cells used to
    # blend toward the track for sub-cell precision, but integer percentages
    # almost never land on a cell boundary, so nearly every bar carried a third
    # muddy colour a few points off the track (18% of 6 cells left the second
    # cell 8% filled). The number beside the bar already carries the precision;
    # the bar only has to be readable at a glance.
    $filled = [int][math]::Round($p / 100 * $Cells)
    # Any nonzero usage lights at least one cell, so a barely-touched quota
    # still reads as touched rather than as untouched.
    if ($filled -eq 0 -and $p -gt 0) { $filled = 1 }

    $bar = ''
    for ($i = 0; $i -lt $Cells; $i++) {
        $rgb = if ($i -lt $filled) { $CCFill } else { $CCTrack }
        $bar += "$e[48;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m "
    }

    # "How much is left" is only half the question -- the other half is how long
    # until it refills. 90% with eight minutes to go is a coffee break; 90% with
    # three hours to go changes what you work on next.
    $until = ''
    if ($ResetsAt -gt 0) {
        $s = [int]($ResetsAt - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        if ($s -gt 0) {
            $d = [math]::Floor($s / 86400); $h = [math]::Floor(($s % 86400) / 3600); $m = [math]::Floor(($s % 3600) / 60)
            $until = if ($d -gt 0) { "${d}d${h}h" } elseif ($h -gt 0) { "${h}h${m}m" } else { "${m}m" }
            $until = "$dim $until$off"
        }
    }

    "$fg$('{0,-3}' -f $Label)$off $bar$off $e[38;2;$($CCFill[0]);$($CCFill[1]);$($CCFill[2])m$('{0,3}' -f [int][math]::Round($p))$dim%$off$until"
}

# The three meters are one cluster, separated by space rather than the pipe that
# divides unrelated fields. They answer one question together: how much room is
# left, over three horizons.
$gauges = @()
if ($shown[0] -ge 0) { $gauges += (New-CCGauge 'CTX' $shown[0]) }
if ($shown[1] -ge 0) { $gauges += (New-CCGauge '5H' $shown[1] $fiveAt) }
if ($shown[2] -ge 0) { $gauges += (New-CCGauge '7D' $shown[2] $sevenAt) }
if ($gauges) { $parts += ($gauges -join '  ') }

# git branch, read straight from .git/HEAD (no git.exe spawn -- keeps it snappy)
$headFile = "$root\.git\HEAD"
if ([IO.File]::Exists($headFile)) {
    $head = $null
    try { $head = [IO.File]::ReadAllText($headFile).Trim() } catch {}
    if ($head) {
        $branch = if ($head -match '^ref: refs/heads/(.+)$') { $Matches[1] } else { $head.Substring(0, 7) }
        # plain text, not a powerline glyph -- no Nerd Font required
        $parts += "$dim git:$branch$off"
    }
}

$parts += $pathPart

$model = $j.model.display_name   # rendered on row two, leading the mode cluster

# --- second row: session totals and mode ------------------------------------
# Row one is full, and these are reference figures rather than things you steer
# by, so they get the quieter row. Everything here is dim by default; only the
# values that carry meaning take colour.
$row2 = @()

# The cat leads the row. Row one is measurement and has to stay legible under
# truncation; row two is where a moving thing can live without competing with
# anything. Subagent activity outranks the busy/idle split, since work is in
# flight even when the main loop sits still waiting on it.
$rage = (Get-SubagentActivity -SessionId $j.session_id -Project $proj) -gt 0
$row2 += (Get-BongoCat -N $st.N -Busy $st.Busy -Rage $rage -Tint $tint)

# Mode flags read live rather than latched: they change because you just changed
# them with /effort or /fast, so the point is to see it immediately. Only states
# worth noticing are printed -- a row that always says the same thing is a row
# you stop reading.
#
# The model leads this cluster and effort follows it directly: which model is
# answering and how hard it is being asked to think are one fact, not two, and
# reading either alone tells you little. This cluster goes first on the row so
# that moving the model off row one does not bury it behind the totals.
#
# Brace the variable rather than backtick-separating it from the literal:
# "$dim`effort" makes `e an ESCAPE character and "$dim`think" makes `t a TAB,
# so the labels came out as "ffort" and "hink" with control characters wedged
# in front. ${dim} ends the variable name unambiguously and escapes nothing.
$flags = @()
if ($model) { $flags += "$tint$model$off" }
# Labels take the plain foreground, values take the project colour -- the same
# split as the meter labels on row one. "think" is a label with no value of its
# own, so it stays plain; FAST and the vim mode are values, so they stay tinted.
if ($j.effort.level) { $flags += "${fg}effort$off $tint$($j.effort.level)$off" }
if ($j.fast_mode) { $flags += "${tint}FAST$off" }
if ($j.thinking.enabled) { $flags += "${fg}think$off" }
if ($j.output_style.name -and $j.output_style.name -ne 'default') { $flags += "${fg}style$off $tint$($j.output_style.name)$off" }
if ($j.agent.name) { $flags += "${fg}agent$off $tint$($j.agent.name)$off" }
if ($j.vim.mode) { $flags += "$tint$($j.vim.mode)$off" }
if ($flags) { $row2 += ($flags -join "$dim  $off") }

# Tokens lead, cost follows in parentheses: the token counts are the work done,
# the dollar figure is what that work was priced at. Cost stays a client-side
# estimate and may differ from the actual bill.
#
# The arrows are U+2193/U+2191, which are East-Asian *ambiguous* width and so
# render two columns wide under a CJK font. That was fatal for the bar art,
# where a mis-measured glyph threw whole rows out of alignment -- here it only
# makes this row slightly wider, since nothing is aligned against it.
function Format-Tokens {
    param([double]$N)
    if ($N -ge 1e6) { '{0:N1}M' -f ($N / 1e6) }
    elseif ($N -ge 1e3) { '{0:N1}k' -f ($N / 1e3) }
    else { '{0:N0}' -f $N }
}

if ($tokIn -gt 0 -or $tokOut -gt 0 -or $costShown -ge 0) {
    # Arrows are labels, not values -- plain foreground, same as every other
    # label on both rows.
    $seg = "$fg↓$off$tint$(Format-Tokens $tokIn)$off $fg↑$off$tint$(Format-Tokens $tokOut)$off"
    if ($costShown -ge 0) { $seg += "$dim (`$$('{0:N2}' -f $costShown))$off" }
    $row2 += $seg
}

if ($addShown -ge 0 -or $delShown -ge 0) {
    $a = [int][math]::Max(0, $addShown); $d = [int][math]::Max(0, $delShown)
    $row2 += "$e[38;2;95;191;98m+$a$off $e[38;2;224;82;82m-$d$off"
}

# The nameplate is already out. What is left is everything after it, emitted as
# a second flush. Raw UTF-8 bytes rather than the PowerShell output stream:
# PowerShell 7 strips ANSI escapes from anything it renders to a redirected
# stdout (the $PSStyle.OutputRendering = 'Host' default) and Claude Code always
# captures this stdout, so returning the string normally drops every colour;
# writing bytes also means [Console]::OutputEncoding never has to be set, which
# was the single most expensive call this script made.
$sep = "$fg  |  $off"
$tail = ''
if ($parts) { $tail = $sep + ($parts -join $sep) }
if ($row2) { $tail += [Environment]::NewLine + ' ' + ($row2 -join $sep) }

# Bank the tail only when the payload actually parsed. A run with unreadable
# stdin still renders something -- quotas from the shared file, the path from
# the working directory -- and letting that degraded version overwrite the cache
# would poison every later fallback with it. Cache good renders, fall back to
# the cache whenever this render came up short.
if ($j -and $tail) {
    Write-CCFile $linePath $tail
} elseif (-not $j -and [IO.File]::Exists($linePath)) {
    try { $tail = [IO.File]::ReadAllText($linePath) } catch {}
}

Emit ($tail + [Environment]::NewLine)
