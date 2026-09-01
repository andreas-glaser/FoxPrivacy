<#
  FoxPrivacy Windows test suite.

  Mirrors the checks in tests/run.sh that matter on Windows: that the PowerShell
  installer produces byte for byte the same policy file as the shell installer,
  and that install, backup, verify, and uninstall behave the same way.

  The committed fixtures in tests/fixtures are the shared contract between the
  two implementations.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $testDir
$installer = Join-Path $repoRoot 'install\foxprivacy.ps1'
$fixtures = Join-Path $repoRoot 'tests\fixtures'

$script:pass = 0
$script:fail = 0

# A root for the checks that only build a policy file and never install it.
$script:BuildRoot = Join-Path ([IO.Path]::GetTempPath()) ("fp-build-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $script:BuildRoot -Force
$script:BuildEnv = @{ FOXPRIVACY_ROOT = $script:BuildRoot }

function Test-Ok { param([string]$Name) $script:pass++; Write-Host "ok   $Name" }
function Test-Fail {
    param([string]$Name, [string]$Detail = '')
    $script:fail++
    Write-Host "FAIL $Name" -ForegroundColor Red
    if ($Detail) { Write-Host "     $Detail" -ForegroundColor Red }
}
function Test-Check {
    param([string]$Name, $Expected, $Actual)
    if ($Expected -eq $Actual) { Test-Ok $Name }
    else { Test-Fail $Name "expected [$Expected] got [$Actual]" }
}
function Test-Section { param([string]$Name) Write-Host ''; Write-Host "== $Name" }

# Windows has powershell.exe, everything else has pwsh. Resolving it here lets
# this suite run on Linux and macOS as well, which is the only way the Windows
# installer gets executed at all before a Windows CI runner sees it.
$script:PwshExe = $(
    foreach ($candidate in 'powershell', 'pwsh') {
        $found = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($found) { $found.Source; break }
    }
)
if (-not $script:PwshExe) { throw 'no powershell or pwsh on PATH' }

# Runs the installer in a child process so exit codes and $env changes are real.
function Invoke-Installer {
    param([string[]]$Arguments, [hashtable]$Env = @{})
    $saved = @{}
    foreach ($k in $Env.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $Env[$k])
    }
    try {
        # -ExecutionPolicy exists only on Windows; passing it to pwsh on Linux
        # is an error, so it is added only where it means something.
        $extra = @()
        if ([System.Environment]::OSVersion.Platform -eq 'Win32NT') {
            $extra = @('-ExecutionPolicy', 'Bypass')
        }
        $output = & $script:PwshExe -NoProfile @extra -File $installer @Arguments 2>&1 |
            Out-String
        return @{ Output = $output; ExitCode = $LASTEXITCODE }
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}

function Get-JsonBody {
    param([string]$Output)
    $lines = $Output -split "`r?`n"
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq '{') { $start = $i; break }
    }
    if ($start -lt 0) { return '' }
    return (($lines[$start..($lines.Count - 1)] -join "`n").TrimEnd() + "`n")
}

# ------------------------------------------------------------------ build ----

Test-Section 'build'

$version = (Invoke-Installer -Arguments @('-Version') -Env $script:BuildEnv).Output.Trim()
Test-Check 'version matches VERSION file' (Get-Content (Join-Path $repoRoot 'VERSION')).Trim() $version

foreach ($preset in @('standard', 'strict')) {
    $result = Invoke-Installer -Arguments @('-Profile', $preset, '-DryRun') -Env $script:BuildEnv
    $body = Get-JsonBody $result.Output

    try { $null = $body | ConvertFrom-Json; Test-Ok "$preset profile is valid JSON" }
    catch { Test-Fail "$preset profile is valid JSON" $_.Exception.Message }

    $fixturePath = Join-Path $fixtures "$preset.json"
    $expected = [IO.File]::ReadAllText($fixturePath) -replace "`r`n", "`n"
    if ($body -eq $expected) {
        Test-Ok "$preset output is byte identical to the shell installer"
    } else {
        Test-Fail "$preset output is byte identical to the shell installer" `
            "PowerShell and sh disagree; see tests/fixtures/$preset.json"
        $eLines = $expected -split "`n"
        $aLines = $body -split "`n"
        for ($i = 0; $i -lt [Math]::Max($eLines.Count, $aLines.Count); $i++) {
            $e = if ($i -lt $eLines.Count) { $eLines[$i] } else { '<missing>' }
            $a = if ($i -lt $aLines.Count) { $aLines[$i] } else { '<missing>' }
            if ($e -ne $a) { Write-Host "     line $($i + 1): expected [$e] got [$a]" -ForegroundColor Red; break }
        }
    }
}

$again = Get-JsonBody (Invoke-Installer -Arguments @('-Profile', 'standard', '-DryRun') -Env $script:BuildEnv).Output
$once = Get-JsonBody (Invoke-Installer -Arguments @('-Profile', 'standard', '-DryRun') -Env $script:BuildEnv).Output
Test-Check 'standard profile is deterministic' $once $again

$custom = Get-JsonBody (Invoke-Installer -Arguments @(
    '-Profile', 'standard', '-Enable', 'captive-portal', '-Disable', 'telemetry', '-DryRun') -Env $script:BuildEnv).Output
$customDoc = $custom | ConvertFrom-Json
Test-Check '-Enable adds a feature' $false $customDoc.policies.CaptivePortal
if ($customDoc.policies.PSObject.Properties.Name -contains 'DisableTelemetry') {
    Test-Fail '-Disable removes a feature'
} else { Test-Ok '-Disable removes a feature' }

Test-Check 'an unknown profile is rejected' 1 (Invoke-Installer -Arguments @('-Profile', 'nonsense', '-DryRun') -Env $script:BuildEnv).ExitCode
Test-Check 'an unknown feature id is rejected' 1 (Invoke-Installer -Arguments @('-Enable', 'no-such-feature', '-DryRun') -Env $script:BuildEnv).ExitCode

# --------------------------------------------------------- install cycle ----

Test-Section 'install cycle'

$root = Join-Path ([IO.Path]::GetTempPath()) ("fp-" + [Guid]::NewGuid().ToString('N'))
$target = Join-Path $root 'Program Files\Mozilla Firefox\distribution\policies.json'
$state = Join-Path $root 'ProgramData\FoxPrivacy\state'
$envRoot = @{ FOXPRIVACY_ROOT = $root }

$r = Invoke-Installer -Arguments @('-Profile', 'standard') -Env $envRoot
Test-Check 'install exits cleanly' 0 $r.ExitCode
if (Test-Path $target) { Test-Ok 'install writes the policy file' } else { Test-Fail 'install writes the policy file' $r.Output }
if (Test-Path $state) { Test-Ok 'install records state' } else { Test-Fail 'install records state' }

if (Test-Path $target) {
    $written = [IO.File]::ReadAllText($target)
    Test-Check 'the installed file has no CRLF' 0 ([regex]::Matches($written, "`r").Count)
    $bytes = [IO.File]::ReadAllBytes($target)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Test-Check 'the installed file has no UTF-8 BOM' $false $hasBom
    Test-Check 'the installed file matches the fixture' `
        ([IO.File]::ReadAllText((Join-Path $fixtures 'standard.json')) -replace "`r`n", "`n") $written
}

Test-Check 'verify reports a clean install' 0 (Invoke-Installer -Arguments @('-Verify') -Env $envRoot).ExitCode

$backups = @(Get-ChildItem -Path $root -Recurse -Filter '*.foxprivacy-backup-*' -ErrorAction SilentlyContinue)
Test-Check 'a fresh install creates no backup' 0 $backups.Count

$null = Invoke-Installer -Arguments @('-Profile', 'strict') -Env $envRoot
$backups = @(Get-ChildItem -Path $root -Recurse -Filter '*.foxprivacy-backup-*' -ErrorAction SilentlyContinue)
Test-Check 'reinstalling over our own file creates no backup' 0 $backups.Count

Add-Content -LiteralPath $target -Value 'tampered'
Test-Check 'verify detects a modified file' 2 (Invoke-Installer -Arguments @('-Verify') -Env $envRoot).ExitCode
Test-Check 'uninstall refuses to remove a modified file' 1 (Invoke-Installer -Arguments @('-Uninstall') -Env $envRoot).ExitCode
if (Test-Path $target) { Test-Ok 'the modified file is left alone' } else { Test-Fail 'the modified file is left alone' }
Test-Check '-Force removes a modified file' 0 (Invoke-Installer -Arguments @('-Uninstall', '-Force') -Env $envRoot).ExitCode
if (-not (Test-Path $target)) { Test-Ok 'uninstall removes the policy file' } else { Test-Fail 'uninstall removes the policy file' }
if (-not (Test-Path $state)) { Test-Ok 'uninstall removes the state file' } else { Test-Fail 'uninstall removes the state file' }

Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

# ------------------------------------------------------ backup and restore ----

Test-Section 'backup and restore'

$root = Join-Path ([IO.Path]::GetTempPath()) ("fp-" + [Guid]::NewGuid().ToString('N'))
$target = Join-Path $root 'Program Files\Mozilla Firefox\distribution\policies.json'
$state = Join-Path $root 'ProgramData\FoxPrivacy\state'
$envRoot = @{ FOXPRIVACY_ROOT = $root }

$null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
$existing = '{"policies":{"DisableDeveloperTools":true}}'
[IO.File]::WriteAllText($target, $existing)
$existingHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash

$null = Invoke-Installer -Arguments @('-Profile', 'standard') -Env $envRoot
$backup = @(Get-ChildItem -Path $root -Recurse -Filter '*.foxprivacy-backup-*')
Test-Check 'an existing policies.json is backed up' 1 $backup.Count
if ($backup.Count -eq 1) {
    Test-Check 'the backup is byte identical to what was there' `
        $existingHash (Get-FileHash -LiteralPath $backup[0].FullName -Algorithm SHA256).Hash
}

$null = Invoke-Installer -Arguments @('-Profile', 'strict') -Env $envRoot
Test-Check 'reinstalling does not create a second backup' 1 `
    (@(Get-ChildItem -Path $root -Recurse -Filter '*.foxprivacy-backup-*')).Count

$null = Invoke-Installer -Arguments @('-Uninstall') -Env $envRoot
Test-Check 'uninstall restores the original file byte for byte' `
    $existingHash (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
Test-Check 'uninstall leaves no backup behind' 0 `
    (@(Get-ChildItem -Path $root -Recurse -Filter '*.foxprivacy-backup-*' -ErrorAction SilentlyContinue)).Count

Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

# ------------------------------------------------------- foreign policies ----

Test-Section "someone else's policies.json"

$root = Join-Path ([IO.Path]::GetTempPath()) ("fp-" + [Guid]::NewGuid().ToString('N'))
$target = Join-Path $root 'Program Files\Mozilla Firefox\distribution\policies.json'
$envRoot = @{ FOXPRIVACY_ROOT = $root }
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
[IO.File]::WriteAllText($target, '{"policies":{"DisableDeveloperTools":true}}')
$foreignHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash

Test-Check 'uninstall refuses a file FoxPrivacy did not install' 1 `
    (Invoke-Installer -Arguments @('-Uninstall') -Env $envRoot).ExitCode
Test-Check 'and leaves it untouched' $foreignHash (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
Test-Check 'verify reports a foreign policy file' 2 (Invoke-Installer -Arguments @('-Verify') -Env $envRoot).ExitCode

Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

$root = Join-Path ([IO.Path]::GetTempPath()) ("fp-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
Test-Check 'verify reports nothing installed' 1 `
    (Invoke-Installer -Arguments @('-Verify') -Env @{ FOXPRIVACY_ROOT = $root }).ExitCode
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- dry run ----

Test-Section 'dry run'

$root = Join-Path ([IO.Path]::GetTempPath()) ("fp-" + [Guid]::NewGuid().ToString('N'))
$target = Join-Path $root 'Program Files\Mozilla Firefox\distribution\policies.json'
$null = New-Item -ItemType Directory -Path $root -Force
$null = Invoke-Installer -Arguments @('-Profile', 'standard', '-DryRun') -Env @{ FOXPRIVACY_ROOT = $root }
if (-not (Test-Path $target)) { Test-Ok 'dry run writes nothing' } else { Test-Fail 'dry run writes nothing' }
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

# ---------------------------------------------------------- broken record ----

Test-Section 'an unreadable record'

$root = Join-Path ([IO.Path]::GetTempPath()) ("fp-" + [Guid]::NewGuid().ToString('N'))
$target = Join-Path $root 'Program Files\Mozilla Firefox\distribution\policies.json'
$state = Join-Path $root 'ProgramData\FoxPrivacy\state'
$envRoot = @{ FOXPRIVACY_ROOT = $root }
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $state) -Force
[IO.File]::WriteAllText($target, '{"policies":{"DisableDeveloperTools":true}}')
[IO.File]::WriteAllText($state, "garbage`n")

Test-Check 'uninstall refuses an unreadable record' 1 `
    (Invoke-Installer -Arguments @('-Uninstall') -Env $envRoot).ExitCode
if (Test-Path $state) { Test-Ok 'and keeps the record instead of deleting it' }
else { Test-Fail 'and keeps the record instead of deleting it' }
if (Test-Path $target) { Test-Ok 'and leaves the policy file alone' }
else { Test-Fail 'and leaves the policy file alone' }
Test-Check 'verify refuses an unreadable record' 1 `
    (Invoke-Installer -Arguments @('-Verify') -Env $envRoot).ExitCode

Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

# ------------------------------------------------------------ no terminal ----

Test-Section 'without a terminal'

# -Profile standard once fell through to the interactive menu and blocked on
# Read-Host, which is the command the README tells people to run. In CI that
# hung a job for thirteen minutes. Both halves are pinned here: the profile must
# install, and a menu with no keyboard must fail instead of waiting.
$root = Join-Path ([IO.Path]::GetTempPath()) ("fp-" + [Guid]::NewGuid().ToString('N'))
$target = Join-Path $root 'Program Files\Mozilla Firefox\distribution\policies.json'
$envRoot = @{ FOXPRIVACY_ROOT = $root }

$r = Invoke-Installer -Arguments @('-Profile', 'standard') -Env $envRoot
Test-Check '-Profile installs rather than opening the menu' 0 $r.ExitCode
if (Test-Path $target) { Test-Ok 'and it actually wrote the file' }
else { Test-Fail 'and it actually wrote the file' $r.Output }

$r = Invoke-Installer -Arguments @() -Env $envRoot
Test-Check 'no arguments and no terminal exits with an error' 1 $r.ExitCode
if ($r.Output -match 'needs a terminal') { Test-Ok 'and explains why instead of hanging' }
else { Test-Fail 'and explains why instead of hanging' $r.Output }

Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

# ----------------------------------------------------------------- result ----

Write-Host ''
Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0

Remove-Item -Recurse -Force $script:BuildRoot -ErrorAction SilentlyContinue
