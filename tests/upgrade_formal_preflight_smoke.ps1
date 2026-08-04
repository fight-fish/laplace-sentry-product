[CmdletBinding()]
param(
    [ValidateSet('all', 'source-target', 'runtime-observation', 'protected-data', 'path-boundary')]
    [string[]]$Group = @('all'),

    [ValidateSet('all', 'success', 'source-dirty', 'target-missing', 'marker-missing', 'marker-different', 'marker-unknown', 'marker-non-ancestor', 'managed-drift', 'delete-and-requirements-policy', 'ui-active-lock-ambiguous', 'owned-daemon-worker', 'stale-registry-warning', 'pid-reuse-unregistered-worker', 'protected-missing-unreadable', 'observation-escape', 'observation-frontend-overlap', 'observation-backend-overlap', 'frontend-backend-overlap', 'outside-temp-boundary')]
    [string[]]$Case = @('all'),

    [ValidateRange(10, 600)]
    [int]$CaseTimeoutSeconds = 60
)

<#
.SYNOPSIS
Exercises the formal read-only preflight with TEMP-only fake targets and observations.

.DESCRIPTION
Purpose: prove PreflightFormal pass/reject/warning contracts without depending on or changing the live runtime.
Inputs: repository HEAD, scripts/upgrade.ps1, TEMP fake targets, generated observation JSON.
Outputs: per-group/per-case START/PASS/SKIP/FAIL/TIMEOUT lines plus a final PASS line on stdout; assertion details on failure.
SSOT Output: process exit code; zero means every required fixture case passed.
Exit codes: 0 all assertions passed, 1 any assertion or fixture cleanup failed.
SKIP conditions: unselected -Group / -Case selector entries.
FAIL conditions: any wrong JSON/result/tag/exit code, fake-tree mutation, boundary escape, or residue.
Order-sensitive checks: case mutation completes before the immutable before-snapshot is captured.
Side effects: writes and removes only this test's verified strict child of system TEMP.
#>

# 這支腳本在做什麼：用 TEMP 假正式副本與假程序觀察，驗證只讀 Preflight 的完整正負向契約。
# 這支腳本不做什麼：不讀寫正式副本、不啟停程序、不清 registry、不呼叫正式 apply。
# 常改區塊：case observation 與預期 tag。
# 不要亂動的區塊：TEMP 邊界、前後指紋、stdout JSON 可解析性與清理驗證。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$UpgradeScript = Join-Path $RepoRoot 'scripts\upgrade.ps1'
$TempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
$SuiteRoot = Join-Path $TempBase ("LaplaceSentryFormalPreflightSmoke-" + [Guid]::NewGuid().ToString('N'))
$HeadShort = (& git -C $RepoRoot rev-parse --short HEAD).Trim()
$SelectedGroups = @($Group)
$SelectedCases = @($Case)
$RunAllGroups = $SelectedGroups -contains 'all'
$RunAllCases = $SelectedCases -contains 'all'

function Test-SmokeGroup {
    param([Parameter(Mandatory = $true)][string]$Name)
    return [bool]($RunAllGroups -or ($SelectedGroups -contains $Name))
}

function Test-SmokeCase {
    param([Parameter(Mandatory = $true)][string]$Name)
    return [bool]($RunAllCases -or ($SelectedCases -contains $Name))
}

function Invoke-SmokeGroup {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    if (-not (Test-SmokeGroup $Name)) {
        Write-Output "preflight smoke group: SKIP name=$Name"
        return
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Write-Output "preflight smoke group: START name=$Name"
    try {
        & $Action
        $watch.Stop()
        Write-Output "preflight smoke group: PASS name=$Name duration_ms=$($watch.ElapsedMilliseconds)"
    }
    catch {
        $watch.Stop()
        Write-Output ("preflight smoke group: FAIL name={0} duration_ms={1} error={2}" -f $Name, $watch.ElapsedMilliseconds, $_.Exception.Message)
        throw
    }
}

function Invoke-SmokeCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    if (-not (Test-SmokeCase $Name)) {
        Write-Output "preflight smoke case: SKIP name=$Name"
        return
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Write-Output "preflight smoke case: START name=$Name"
    try {
        & $Action
        $watch.Stop()
        Write-Output "preflight smoke case: PASS name=$Name duration_ms=$($watch.ElapsedMilliseconds)"
    }
    catch {
        $watch.Stop()
        $status = 'FAIL'
        if ($_.Exception.Message -match 'UPGRADE_PREFLIGHT_TIMEOUT') { $status = 'TIMEOUT' }
        Write-Output ("preflight smoke case: {0} name={1} duration_ms={2} error={3}" -f $status, $Name, $watch.ElapsedMilliseconds, $_.Exception.Message)
        throw
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-StrictTempPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    Assert-True ($resolved.StartsWith($TempBase + '\', [System.StringComparison]::OrdinalIgnoreCase)) "Path escaped TEMP: $resolved"
}

function Remove-TestTree {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-StrictTempPath $Path
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
}

function Copy-ManagedTree {
    param([Parameter(Mandatory = $true)]$Case)
    New-Item -ItemType Directory -Path $Case.Frontend, $Case.Backend, (Join-Path $Case.Backend 'data') -Force | Out-Null
    foreach ($entry in @('assets', 'src', 'requirements.txt', 'run_ui.bat', 'run_ui.vbs', 'run_dev_ui.bat')) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot "Frontend\$entry") -Destination (Join-Path $Case.Frontend $entry) -Recurse -Force
    }
    foreach ($entry in @('main.py', 'requirements.txt', 'src')) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot "Backend\$entry") -Destination (Join-Path $Case.Backend $entry) -Recurse -Force
    }
    $HeadShort | Set-Content -LiteralPath (Join-Path $Case.Frontend 'version.txt') -Encoding ASCII -NoNewline
    $HeadShort | Set-Content -LiteralPath (Join-Path $Case.Backend 'version.txt') -Encoding ASCII -NoNewline
    "[General]`r`neye_size=480" | Set-Content -LiteralPath (Join-Path $Case.Frontend 'sentry_config.ini') -Encoding UTF8
    '[{"uuid":"fixture","name":"fixture"}]' | Set-Content -LiteralPath (Join-Path $Case.Backend 'data\projects.json') -Encoding UTF8
}

function New-Observation {
    return [ordered]@{
        source_dirty = $false
        tracked_deletions = @()
        requirements_changes = @()
        force_non_ancestor = $false
        protected_unreadable = @()
        lock_exists = $false
        ui = @()
        daemon = @()
        workers = @()
        registry = @()
    }
}

function New-TestCase {
    param([Parameter(Mandatory = $true)][string]$Name)
    $root = Join-Path $SuiteRoot $Name
    $case = [pscustomobject]@{
        Name = $Name
        Root = $root
        Frontend = Join-Path $root 'frontend-target'
        Backend = Join-Path $root 'backend-target'
        Observation = Join-Path $root 'observation.json'
    }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Copy-ManagedTree -Case $case
    return $case
}

function Write-Observation {
    param([Parameter(Mandatory = $true)]$Case, [Parameter(Mandatory = $true)]$Observation)
    $Observation | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Case.Observation -Encoding UTF8
}

function Get-TreeFingerprint {
    param([Parameter(Mandatory = $true)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return '<missing>' }
    $rows = foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
        "$relative|$($file.Length)|$($file.LastWriteTimeUtc.ToString('o'))|$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)"
    }
    return ($rows -join "`n")
}

function Quote-Argument {
    param([Parameter(Mandatory = $true)][string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-PreflightProcess {
    param(
        [Parameter(Mandatory = $true)][string]$IsolationRoot,
        [Parameter(Mandatory = $true)][string]$Frontend,
        [Parameter(Mandatory = $true)][string]$Backend,
        [Parameter(Mandatory = $true)][string]$Observation
    )
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-Argument $UpgradeScript),
        '-Mode', 'PreflightFormal',
        '-IsolationRoot', (Quote-Argument $IsolationRoot),
        '-FrontendTarget', (Quote-Argument $Frontend),
        '-BackendTarget', (Quote-Argument $Backend),
        '-PreflightObservationPath', (Quote-Argument $Observation)
    ) -join ' '
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($CaseTimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            throw "[UPGRADE_PREFLIGHT_TIMEOUT] case command exceeded ${CaseTimeoutSeconds}s."
        }
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $json = $null
        try { $json = $stdout.Trim() | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "[$IsolationRoot] stdout was not one parseable JSON document. stdout=$stdout stderr=$stderr" }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Json = $json; Stdout = $stdout; Stderr = $stderr }
    }
    finally {
        $process.Dispose()
    }
}

function Assert-ResultTags {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][int]$ExpectedExit,
        [string[]]$FailureTags = @(),
        [string[]]$WarningTags = @()
    )
    Assert-True ($Result.ExitCode -eq $ExpectedExit) "Expected exit $ExpectedExit, got $($Result.ExitCode). stderr=$($Result.Stderr)"
    $actualFailures = @($Result.Json.failures | ForEach-Object { $_.tag })
    $actualWarnings = @($Result.Json.warnings | ForEach-Object { $_.tag })
    foreach ($tag in $FailureTags) { Assert-True ($tag -in $actualFailures) "Missing failure tag $tag; actual=$($actualFailures -join ',')" }
    foreach ($tag in $WarningTags) { Assert-True ($tag -in $actualWarnings) "Missing warning tag $tag; actual=$($actualWarnings -join ',')" }
    if ($ExpectedExit -eq 0) {
        Assert-True ($Result.Json.safe_to_upgrade -eq $true -and $Result.Json.result -eq 'pass') 'Success result contract mismatch.'
    }
    else {
        Assert-True ($Result.Json.safe_to_upgrade -eq $false -and $Result.Json.result -in @('reject', 'indeterminate')) 'Reject result contract mismatch.'
    }
    Assert-True ($Result.Json.excluded.paper_watcher -eq $true) 'paper watcher exclusion is missing.'
}

function Run-Case {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Arrange,
        [Parameter(Mandatory = $true)][int]$ExpectedExit,
        [string[]]$FailureTags = @(),
        [string[]]$WarningTags = @()
    )
    Invoke-SmokeCase $Name {
        $case = New-TestCase $Name
        try {
            $observation = New-Observation
            & $Arrange $case $observation
            Write-Observation -Case $case -Observation $observation
            $before = Get-TreeFingerprint $case.Root
            $result = Invoke-PreflightProcess -IsolationRoot $case.Root -Frontend $case.Frontend -Backend $case.Backend -Observation $case.Observation
            $after = Get-TreeFingerprint $case.Root
            Assert-True ($before -ceq $after) "$Name changed fake target/observation content or timestamps."
            Assert-ResultTags -Result $result -ExpectedExit $ExpectedExit -FailureTags $FailureTags -WarningTags $WarningTags
        }
        finally {
            Remove-TestTree $case.Root
        }
    }
}

try {
    Assert-StrictTempPath $SuiteRoot
    New-Item -ItemType Directory -Path $SuiteRoot -Force | Out-Null

    Invoke-SmokeGroup 'source-target' {
        Run-Case 'success' { param($case, $o) } 0
        Run-Case 'source-dirty' { param($case, $o) $o.source_dirty = $true } 2 @('[UPGRADE_SOURCE_DIRTY]')
        Run-Case 'target-missing' { param($case, $o) Remove-TestTree $case.Backend } 2 @('[UPGRADE_TARGET_FAIL]', '[UPGRADE_VERSION_FAIL]')
        Run-Case 'marker-missing' { param($case, $o) Remove-Item -LiteralPath (Join-Path $case.Frontend 'version.txt') -Force } 2 @('[UPGRADE_VERSION_FAIL]')
        Run-Case 'marker-different' { param($case, $o) 'different' | Set-Content -LiteralPath (Join-Path $case.Backend 'version.txt') -Encoding ASCII -NoNewline } 2 @('[UPGRADE_VERSION_FAIL]')
        Run-Case 'marker-unknown' { param($case, $o) 'not-a-commit' | Set-Content -LiteralPath (Join-Path $case.Frontend 'version.txt') -Encoding ASCII -NoNewline; 'not-a-commit' | Set-Content -LiteralPath (Join-Path $case.Backend 'version.txt') -Encoding ASCII -NoNewline } 2 @('[UPGRADE_VERSION_FAIL]')
        Run-Case 'marker-non-ancestor' { param($case, $o) $o.force_non_ancestor = $true } 2 @('[UPGRADE_VERSION_FAIL]')
        Run-Case 'managed-drift' {
            param($case, $o)
            Remove-Item -LiteralPath (Join-Path $case.Frontend 'run_ui.vbs') -Force
            'extra' | Set-Content -LiteralPath (Join-Path $case.Frontend 'src\extra-managed.txt') -Encoding UTF8
            'drift' | Add-Content -LiteralPath (Join-Path $case.Backend 'main.py') -Encoding UTF8
        } 2 @('[UPGRADE_TARGET_DRIFT]')
        Run-Case 'delete-and-requirements-policy' {
            param($case, $o)
            $o.tracked_deletions = @('Frontend/src/removed.py')
            $o.requirements_changes = @('Backend/requirements.txt')
        } 2 @('[UPGRADE_SOURCE_DELETE]', '[UPGRADE_POLICY_FAIL]')
    }

    Invoke-SmokeGroup 'runtime-observation' {
        Run-Case 'ui-active-lock-ambiguous' {
            param($case, $o)
            $o.lock_exists = $true
            $o.ui = @(
                [pscustomobject]@{ pid = 101; owned = $true; ambiguous = $false },
                [pscustomobject]@{ pid = 102; owned = $false; ambiguous = $true }
            )
        } 2 @('[UPGRADE_UI_ACTIVE]', '[UPGRADE_RUNTIME_AMBIGUOUS]')
        Run-Case 'owned-daemon-worker' {
            param($case, $o)
            $o.daemon = @([pscustomobject]@{ pid = 201; owned = $true; ambiguous = $false })
            $o.workers = @([pscustomobject]@{ pid = 202; uuid = 'fixture'; owned = $true; registered = $true; ambiguous = $false })
        } 2 @('[UPGRADE_RUNTIME_ACTIVE]')
        Run-Case 'stale-registry-warning' {
            param($case, $o)
            $o.registry = @([pscustomobject]@{ pid = 301; uuid = 'fixture'; proc_exists = $false; owned = $false; uuid_matches = $false; ambiguous = $false })
        } 0 @() @('[UPGRADE_REGISTRY_STALE]')
        Run-Case 'pid-reuse-unregistered-worker' {
            param($case, $o)
            $o.workers = @([pscustomobject]@{ pid = 302; uuid = 'fixture'; owned = $true; registered = $false; ambiguous = $false })
            $o.registry = @([pscustomobject]@{ pid = 303; uuid = 'fixture'; proc_exists = $true; owned = $false; uuid_matches = $false; ambiguous = $true })
        } 2 @('[UPGRADE_RUNTIME_AMBIGUOUS]')
    }

    Invoke-SmokeGroup 'protected-data' {
        Run-Case 'protected-missing-unreadable' {
            param($case, $o)
            Remove-Item -LiteralPath (Join-Path $case.Backend 'data\projects.json') -Force
            $o.protected_unreadable = @('Frontend/sentry_config.ini')
        } 2 @('[UPGRADE_PROTECTED_DATA_FAIL]')
    }

    Invoke-SmokeGroup 'path-boundary' {
        Invoke-SmokeCase 'observation-escape' {
            $outsideObservation = Join-Path $TempBase ("LaplaceSentryOutsideObservation-" + [Guid]::NewGuid().ToString('N') + '.json')
            try {
                '{}' | Set-Content -LiteralPath $outsideObservation -Encoding UTF8
                $case = New-TestCase 'observation-escape'
                $before = Get-TreeFingerprint $case.Root
                $result = Invoke-PreflightProcess -IsolationRoot $case.Root -Frontend $case.Frontend -Backend $case.Backend -Observation $outsideObservation
                Assert-True ($before -ceq (Get-TreeFingerprint $case.Root)) 'Observation escape rejection changed fixture tree.'
                Assert-ResultTags $result 2 @('[UPGRADE_PREFLIGHT_FAIL]')
                Remove-TestTree $case.Root
            }
            finally { if (Test-Path -LiteralPath $outsideObservation) { Remove-Item -LiteralPath $outsideObservation -Force } }
        }

        Invoke-SmokeCase 'observation-frontend-overlap' {
            $case = New-TestCase 'observation-frontend-overlap'
            try {
                $overlapObservation = Join-Path $case.Frontend 'src\observation.json'
                '{}' | Set-Content -LiteralPath $overlapObservation -Encoding UTF8
                $before = Get-TreeFingerprint $case.Root
                $result = Invoke-PreflightProcess -IsolationRoot $case.Root -Frontend $case.Frontend -Backend $case.Backend -Observation $overlapObservation
                Assert-True ($before -ceq (Get-TreeFingerprint $case.Root)) 'Frontend/observation overlap rejection changed fixture tree.'
                Assert-ResultTags $result 2 @('[UPGRADE_PREFLIGHT_FAIL]')
            }
            finally { Remove-TestTree $case.Root }
        }

        Invoke-SmokeCase 'observation-backend-overlap' {
            $case = New-TestCase 'observation-backend-overlap'
            try {
                $overlapObservation = Join-Path $case.Backend 'src\observation.json'
                '{}' | Set-Content -LiteralPath $overlapObservation -Encoding UTF8
                $before = Get-TreeFingerprint $case.Root
                $result = Invoke-PreflightProcess -IsolationRoot $case.Root -Frontend $case.Frontend -Backend $case.Backend -Observation $overlapObservation
                Assert-True ($before -ceq (Get-TreeFingerprint $case.Root)) 'Backend/observation overlap rejection changed fixture tree.'
                Assert-ResultTags $result 2 @('[UPGRADE_PREFLIGHT_FAIL]')
            }
            finally { Remove-TestTree $case.Root }
        }

        Invoke-SmokeCase 'frontend-backend-overlap' {
            $case = New-TestCase 'frontend-backend-overlap'
            try {
                $before = Get-TreeFingerprint $case.Root
                $result = Invoke-PreflightProcess -IsolationRoot $case.Root -Frontend $case.Frontend -Backend (Join-Path $case.Frontend 'src') -Observation $case.Observation
                Assert-True ($before -ceq (Get-TreeFingerprint $case.Root)) 'Frontend/backend overlap rejection changed fixture tree.'
                Assert-ResultTags $result 2 @('[UPGRADE_PREFLIGHT_FAIL]')
            }
            finally { Remove-TestTree $case.Root }
        }

        Invoke-SmokeCase 'outside-temp-boundary' {
            $forbiddenRoot = Join-Path $RepoRoot 'forbidden-preflight-fixture'
            $result = Invoke-PreflightProcess -IsolationRoot $forbiddenRoot -Frontend (Join-Path $forbiddenRoot 'frontend') -Backend (Join-Path $forbiddenRoot 'backend') -Observation (Join-Path $forbiddenRoot 'observation.json')
            Assert-ResultTags $result 2 @('[UPGRADE_PREFLIGHT_FAIL]')
            Assert-True (-not (Test-Path -LiteralPath $forbiddenRoot)) 'Outside-TEMP boundary check created a repository path.'
        }
    }

    Write-Output '[PASS] formal Preflight fixture cases preserved every fake tree and enforced JSON/exit/boundary contracts.'
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
finally {
    if (Test-Path -LiteralPath $SuiteRoot) { Remove-TestTree $SuiteRoot }
}
