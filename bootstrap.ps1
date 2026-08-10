<#
.SYNOPSIS
    One-line installer for claude-terminal-kit.

.DESCRIPTION
    Run this in a PowerShell 7 window:

        irm https://raw.githubusercontent.com/Berry-G/claude-terminal-kit/main/bootstrap.ps1 | iex

    Downloads the repository archive into a temp folder, runs install.ps1 out of
    it, then deletes the folder. The kit itself lives in %USERPROFILE%\.claude
    after install, so the download is disposable and re-running this is how you
    update.

    `iex` executes a string and cannot pass parameters, so options come from
    environment variables set before the call:

        $env:CCKIT_ROOT      = 'D:\laragon\www'   -> install.ps1 -Root
        $env:CCKIT_RECENT    = '12'               -> install.ps1 -Recent
        $env:CCKIT_TITLEHOOK = '1'                -> install.ps1 -TitleHook
        $env:CCKIT_NOALIAS   = '1'                -> install.ps1 -NoAlias
        $env:CCKIT_BRANCH    = 'main'             which branch to pull
#>

$ErrorActionPreference = 'Stop'

$repo = 'Berry-G/claude-terminal-kit'
$branch = if ($env:CCKIT_BRANCH) { $env:CCKIT_BRANCH } else { 'main' }

# The kit is PowerShell 7 only, and failing here is much clearer than failing
# halfway through install.ps1 on syntax Windows PowerShell cannot parse.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7+ required (running $($PSVersionTable.PSVersion)). Install it with: winget install Microsoft.PowerShell -- then run this again from a pwsh window."
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('cckit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
    $zip = Join-Path $tmp 'kit.zip'
    Write-Host "claude-terminal-kit" -ForegroundColor Cyan
    Write-Host "  downloading $repo@$branch ..." -ForegroundColor Gray
    # -UseBasicParsing keeps this working on hosts with no IE engine available
    Invoke-WebRequest "https://github.com/$repo/archive/refs/heads/$branch.zip" -OutFile $zip -UseBasicParsing

    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force

    # GitHub archives unpack into <repo>-<branch>\, and the branch name may
    # contain slashes that become nested folders -- so find install.ps1 instead
    # of assuming the layout.
    $installer = Get-ChildItem $tmp -Recurse -Filter 'install.ps1' -File |
        Sort-Object { $_.FullName.Length } | Select-Object -First 1
    if (-not $installer) { throw "install.ps1 not found in the downloaded archive ($zip)" }

    # Everything that came out of the zip carries Windows' mark-of-the-web,
    # which blocks execution under the default policy. Strip it before running.
    Get-ChildItem $installer.Directory -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

    $opt = @()
    if ($env:CCKIT_ROOT) { $opt += @('-Root', $env:CCKIT_ROOT) }
    if ($env:CCKIT_RECENT) { $opt += @('-Recent', $env:CCKIT_RECENT) }
    if ($env:CCKIT_TITLEHOOK) { $opt += '-TitleHook' }
    if ($env:CCKIT_NOALIAS) { $opt += '-NoAlias' }

    # A child pwsh with -ExecutionPolicy Bypass, so a restrictive machine policy
    # cannot stop an install the user explicitly asked for.
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $installer.FullName @opt
    if ($LASTEXITCODE -ne 0) { throw "install.ps1 exited with code $LASTEXITCODE" }
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
