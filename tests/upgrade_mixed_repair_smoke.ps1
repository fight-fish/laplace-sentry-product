[CmdletBinding()]
param()

<#
.SYNOPSIS
Proves the ruled formal-target mixed-version repair and exact rollback contract under TEMP.

.DESCRIPTION
Purpose: build deterministic mixed targets from Git objects, exercise prepare/apply/crash reconciliation/rollback, and prove every external boundary stays untouched.
Inputs: fixed repository commits plus generated fake Frontend/Backend targets and process/registry observation under system TEMP.
Outputs: one PASS/FAIL result; all transaction evidence is deleted before exit.
SSOT Output: process exit code; zero means every ruled mixed repair assertion passed.
Exit codes: 0 pass, 1 assertion, script, boundary, or cleanup failure.
SKIP conditions: none.
FAIL conditions: any wrong state ID/action/order/hash/mtime/recovery/boundary result or TEMP residue.
Order-sensitive checks: immutable source snapshots are captured before invoking the repair proof; rollback equality is checked before fixture cleanup.
Side effects: creates and removes only verified strict children of system TEMP; never invokes upgrade.bat or touches formal runtime/Git state.
#>

# 這支腳本在做什麼：用固定 source baseline、adapter override 與 package target 建立真實 24+1+1 混合假目標，證明 adapter/tray 升級、marker-last 與完整回退。
# 這支腳本不做什麼：不讀寫正式副本、不操作真實程序／registry、不 stage／commit，也不把隔離通過當成正式修復。
# 常改區塊：故障注入案例、來源 state ID、reconciliation 與 rollback 斷言。
# 不要亂動的區塊：system TEMP 邊界、正式路徑拒絕、完整 path/existence/length/SHA-256/mtime 比對與最終零殘留。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$UpgradeScript = Join-Path $RepoRoot 'scripts\upgrade.ps1'
$TempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
$SuiteRoot = Join-Path $TempBase ('LaplaceSentryMixedRepairSmoke-' + [Guid]::NewGuid().ToString('N'))
$OutsideRoot = Join-Path $TempBase ('LaplaceSentryMixedRepairOutside-' + [Guid]::NewGuid().ToString('N'))
$GitBranchShim = Join-Path $SuiteRoot '_git-branch-shim\git.cmd'
$RealGitExe = (Get-Command git.exe -ErrorAction Stop).Source
# 在受限 scope 直接讀 PrepareFormal 的正式目標來源，避免 mixed repair smoke 自帶第二份 target 或污染測試 scope。
$TargetCommit = & { . (Join-Path $RepoRoot 'scripts\upgrade_formal_prepare.ps1'); $FormalUpgradeTargetCommit }
$TargetShort = $TargetCommit.Substring(0, 7)
$AdapterCommit = '4f228ae5f31754aa43a918274e3b542b6f0a2144'
$SourceCommit = '971ba498d613c2bb20d46e14855cc0b0a326602a'
$ExpectedAdapterBlob = 'ad49188e2f54c00245f54744e1413cfe83e8d867'
$ExpectedSourceTrayBlob = '13577b3bfa63af7ba320f0a410545503c704b4c2'
$ExpectedTargetTrayBlob = 'bdc98668e3779fa006be5e3c7f05e220776374c2'
$SourceMarker = '1e7bc2b'
$Schema = 'laplace-mixed-source-v1'
$FixedTime = [DateTime]::Parse('2024-01-02T03:04:05.0000000Z', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
$JunctionPath = $null
$SuccessEvidenceSummary = $null

$FrontendAllowlist = @('assets', 'src', 'requirements.txt', 'run_ui.bat', 'run_ui.vbs', 'run_dev_ui.bat')
$BackendAllowlist = @('main.py', 'requirements.txt', 'src')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "[ASSERT_FAIL] $Message" }
}

function Assert-StrictTempPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    Assert-True ($resolved.StartsWith($TempBase + '\', [System.StringComparison]::OrdinalIgnoreCase)) "Path escaped system TEMP: $resolved"
}

function Remove-TestTree {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-StrictTempPath $Path
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
}

function Get-Sha {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-Utf8Sha {
    param([Parameter(Mandatory = $true)][string]$Text)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($algorithm.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '') }
    finally { $algorithm.Dispose() }
}

function Quote-Argument {
    param([Parameter(Mandatory = $true)][string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Initialize-BranchOnlyGitShim {
    $shimRoot = Split-Path -Parent $GitBranchShim
    New-Item -ItemType Directory -Path $shimRoot -Force | Out-Null
    $content = @"
@echo off
if /I "%~1"=="-C" if /I "%~2"=="$RepoRoot" if /I "%~3"=="branch" if /I "%~4"=="--show-current" if "%~5"=="" (
  echo s/S-02-03b/exact-mixed-live-source-baseline
  exit /b 0
)
"$RealGitExe" %*
"@
    Set-Content -LiteralPath $GitBranchShim -Value $content -Encoding ASCII
}

function Assert-BranchOnlyGitShimContract {
    Assert-True ((& $GitBranchShim -C $RepoRoot branch --show-current).Trim() -eq 's/S-02-03b/exact-mixed-live-source-baseline') 'Branch-only Git shim did not simulate the approved working branch.'
    foreach ($revision in @('HEAD', 'origin/main')) {
        $throughShim = (& $GitBranchShim -C $RepoRoot rev-parse $revision).Trim()
        $throughRealGit = (& $RealGitExe -C $RepoRoot rev-parse $revision).Trim()
        Assert-True ($throughShim -eq $throughRealGit) "Branch-only Git shim intercepted non-branch truth: $revision"
    }
}
function Get-ExpectedManagedPaths {
    $pathSpecs = @()
    $pathSpecs += @($FrontendAllowlist | ForEach-Object { 'Frontend/' + $_ })
    $pathSpecs += @($BackendAllowlist | ForEach-Object { 'Backend/' + $_ })
    $paths = @(& git -C $RepoRoot ls-tree -r --name-only $TargetCommit -- @pathSpecs)
    Assert-True ($LASTEXITCODE -eq 0) 'Unable to enumerate target commit package paths.'
    return @($paths | Where-Object { $_ -and $_ -notmatch '(^|/)(__pycache__|\.venv)(/|$)' -and $_ -notmatch '\.pyc$' } | Sort-Object -Unique)
}

function Export-CommitTree {
    param(
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][string[]]$PathSpecs,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$WorkRoot
    )
    New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
    $archive = Join-Path $WorkRoot 'tree.zip'
    $arguments = @('-C', $RepoRoot, 'archive', '--format=zip', "--output=$archive", $Commit, '--') + $PathSpecs
    & git @arguments
    Assert-True ($LASTEXITCODE -eq 0) "git archive failed for $Commit."
    Expand-Archive -LiteralPath $archive -DestinationPath $Destination -Force
    Remove-Item -LiteralPath $archive -Force
}

function Set-FixedFixtureTimes {
    param([Parameter(Mandatory = $true)]$Case)
    foreach ($file in @(Get-ChildItem -LiteralPath $Case.Frontend, $Case.Backend -Recurse -File -Force)) {
        [System.IO.File]::SetLastWriteTimeUtc($file.FullName, $FixedTime)
    }
    [System.IO.File]::SetLastWriteTimeUtc($Case.Observation, $FixedTime)
}

function New-MixedCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateSet('Base', 'OriginallyAbsent', 'ExtraDelete')][string]$Variant = 'Base'
    )
    $root = Join-Path $SuiteRoot $Name
    $build = Join-Path $root 'fixture-build'
    $tree = Join-Path $build 'source'
    $oldTree = Join-Path $build 'old-adapter'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $pathSpecs = @()
    $pathSpecs += @($FrontendAllowlist | ForEach-Object { 'Frontend/' + $_ })
    $pathSpecs += @($BackendAllowlist | ForEach-Object { 'Backend/' + $_ })
    Export-CommitTree -Commit $SourceCommit -PathSpecs $pathSpecs -Destination $tree -WorkRoot (Join-Path $build 'source-archive')
    Export-CommitTree -Commit $AdapterCommit -PathSpecs @('Frontend/src/backend/adapter.py') -Destination $oldTree -WorkRoot (Join-Path $build 'old-archive')

    $frontend = Join-Path $root 'frontend-target'
    $backend = Join-Path $root 'backend-target'
    Move-Item -LiteralPath (Join-Path $tree 'Frontend') -Destination $frontend
    Move-Item -LiteralPath (Join-Path $tree 'Backend') -Destination $backend
    Copy-Item -LiteralPath (Join-Path $oldTree 'Frontend\src\backend\adapter.py') -Destination (Join-Path $frontend 'src\backend\adapter.py') -Force
    $actualSourceTrayBlob = (& git -C $RepoRoot hash-object -- (Join-Path $frontend 'src\tray\tray_app.py')).Trim()
    $actualAdapterBlob = (& git -C $RepoRoot hash-object -- (Join-Path $frontend 'src\backend\adapter.py')).Trim()
    Assert-True ($actualSourceTrayBlob -eq $ExpectedSourceTrayBlob) "Mixed template tray is not the ruled source-baseline blob: actual=$actualSourceTrayBlob expected=$ExpectedSourceTrayBlob"
    Assert-True ($actualAdapterBlob -eq $ExpectedAdapterBlob) "Mixed template adapter is not the ruled override blob: actual=$actualAdapterBlob expected=$ExpectedAdapterBlob"
    Remove-TestTree $build

    New-Item -ItemType Directory -Path (Join-Path $backend 'data'), (Join-Path $frontend '.venv'), (Join-Path $backend 'logs') -Force | Out-Null
    '[General]`r`neye_size=480' | Set-Content -LiteralPath (Join-Path $frontend 'sentry_config.ini') -Encoding UTF8
    '[{"uuid":"fixture-project","name":"must-survive"}]' | Set-Content -LiteralPath (Join-Path $backend 'data\projects.json') -Encoding UTF8
    $SourceMarker | Set-Content -LiteralPath (Join-Path $frontend 'version.txt') -Encoding ASCII -NoNewline
    $SourceMarker | Set-Content -LiteralPath (Join-Path $backend 'version.txt') -Encoding ASCII -NoNewline
    'frontend-unmanaged-guard' | Set-Content -LiteralPath (Join-Path $frontend '.venv\guard.txt') -Encoding UTF8
    'backend-unmanaged-guard' | Set-Content -LiteralPath (Join-Path $backend 'logs\guard.log') -Encoding UTF8
    if ($Variant -eq 'OriginallyAbsent') {
        Remove-Item -LiteralPath (Join-Path $frontend 'run_dev_ui.bat') -Force
    }
    elseif ($Variant -eq 'ExtraDelete') {
        'synthetic-extra-delete-preimage' | Set-Content -LiteralPath (Join-Path $frontend 'src\mixed-extra-delete.fixture') -Encoding UTF8
    }

    $observation = Join-Path $root 'registry-observation.json'
    [ordered]@{
        lock_exists = $false
        ui = @()
        daemon = @()
        workers = @()
        registry = @([ordered]@{ pid = 114348; uuid = 'fixture-stale'; proc_exists = $false; owned = $false; ambiguous = $false })
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $observation -Encoding UTF8

    $case = [pscustomobject]@{
        Name = $Name
        Variant = $Variant
        Root = $root
        Frontend = $frontend
        Backend = $backend
        Stage = Join-Path $root 'staging'
        Transaction = Join-Path $root 'transaction'
        Observation = $observation
        Adapter = Join-Path $frontend 'src\backend\adapter.py'
        Tray = Join-Path $frontend 'src\tray\tray_app.py'
        FrontendMarker = Join-Path $frontend 'version.txt'
        BackendMarker = Join-Path $backend 'version.txt'
        Config = Join-Path $frontend 'sentry_config.ini'
        Projects = Join-Path $backend 'data\projects.json'
        FrontendGuard = Join-Path $frontend '.venv\guard.txt'
        BackendGuard = Join-Path $backend 'logs\guard.log'
    }
    Set-FixedFixtureTimes -Case $case
    return $case
}

function Get-TreeRecords {
    param([Parameter(Mandatory = $true)]$Case)
    $records = @{}
    foreach ($spec in @(
        [pscustomobject]@{ Side = 'Frontend'; Root = $Case.Frontend },
        [pscustomobject]@{ Side = 'Backend'; Root = $Case.Backend }
    )) {
        foreach ($file in @(Get-ChildItem -LiteralPath $spec.Root -Recurse -File -Force | Sort-Object FullName)) {
            $relative = $file.FullName.Substring($spec.Root.Length + 1).Replace('\', '/')
            $key = "$($spec.Side)/$relative"
            $records[$key] = "$key|$($file.Length)|$($file.LastWriteTimeUtc.ToString('o'))|$(Get-Sha $file.FullName)"
        }
    }
    $observation = Get-Item -LiteralPath $Case.Observation -Force
    $records['Registry/observation.json'] = "Registry/observation.json|$($observation.Length)|$($observation.LastWriteTimeUtc.ToString('o'))|$(Get-Sha $Case.Observation)"
    return $records
}

function Get-TreeCanonical {
    param([Parameter(Mandatory = $true)]$Case)
    $records = Get-TreeRecords -Case $Case
    return @($records.Keys | Sort-Object | ForEach-Object { $records[$_] }) -join "`n"
}

function Get-GuardCanonical {
    param([Parameter(Mandatory = $true)]$Case)
    $lines = foreach ($path in @($Case.Config, $Case.Projects, $Case.FrontendGuard, $Case.BackendGuard, $Case.Observation)) {
        $item = Get-Item -LiteralPath $path -Force
        "$path|$($item.Length)|$($item.LastWriteTimeUtc.ToString('o'))|$(Get-Sha $path)"
    }
    return @($lines) -join "`n"
}

function New-StateRecord {
    param([string]$Type, [string]$Side, [string]$Relative, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ record_type = $Type; side = $Side; relative_path = $Relative; exists = $false; length = $null; sha256 = $null; last_write_utc = $null }
    }
    $item = Get-Item -LiteralPath $Path -Force
    return [pscustomobject]@{ record_type = $Type; side = $Side; relative_path = $Relative; exists = $true; length = [int64]$item.Length; sha256 = Get-Sha $Path; last_write_utc = $item.LastWriteTimeUtc.ToString('o') }
}

function ConvertTo-StateLine {
    param($Record)
    $exists = if ($Record.exists) { '1' } else { '0' }
    $length = if ($null -eq $Record.length) { '-' } else { ([int64]$Record.length).ToString([System.Globalization.CultureInfo]::InvariantCulture) }
    $sha = if ($Record.sha256) { $Record.sha256.ToUpperInvariant() } else { '-' }
    $mtime = if ($Record.last_write_utc) { $Record.last_write_utc } else { '-' }
    return "$($Record.record_type)|$($Record.side)|$($Record.relative_path)|$exists|$length|$sha|$mtime"
}

function Get-ExpectedSourceIds {
    param([Parameter(Mandatory = $true)]$Case)
    $software = @()
    foreach ($gitPath in Get-ExpectedManagedPaths) {
        $side = if ($gitPath.StartsWith('Frontend/')) { 'Frontend' } else { 'Backend' }
        $relative = $gitPath.Substring($side.Length + 1)
        $root = if ($side -eq 'Frontend') { $Case.Frontend } else { $Case.Backend }
        $software += New-StateRecord 'managed' $side $relative (Join-Path $root $relative.Replace('/', '\'))
    }
    if ($Case.Variant -eq 'ExtraDelete') {
        $software += New-StateRecord 'managed_extra' 'Frontend' 'src/mixed-extra-delete.fixture' (Join-Path $Case.Frontend 'src\mixed-extra-delete.fixture')
    }
    $software += New-StateRecord 'marker' 'Frontend' 'version.txt' $Case.FrontendMarker
    $software += New-StateRecord 'marker' 'Backend' 'version.txt' $Case.BackendMarker
    $evidence = @($software) + @(
        (New-StateRecord 'protected' 'Frontend' 'sentry_config.ini' $Case.Config),
        (New-StateRecord 'protected' 'Backend' 'data/projects.json' $Case.Projects),
        (New-StateRecord 'registry_observation' 'Registry' 'observation.json' $Case.Observation)
    )
    $softwareCanonical = (@("schema=$Schema") + @($software | Sort-Object record_type, side, relative_path | ForEach-Object { ConvertTo-StateLine $_ })) -join "`n"
    $evidenceCanonical = (@("schema=$Schema") + @($evidence | Sort-Object record_type, side, relative_path | ForEach-Object { ConvertTo-StateLine $_ })) -join "`n"
    return [pscustomobject]@{
        Software = 'sha256:' + (Get-Utf8Sha $softwareCanonical)
        Evidence = 'sha256:' + (Get-Utf8Sha $evidenceCanonical)
        SoftwareCanonical = $softwareCanonical
        EvidenceCanonical = $evidenceCanonical
    }
}

function Invoke-MixedProcess {
    param(
        [Parameter(Mandatory = $true)]$Case,
        [ValidateSet('Apply', 'Rollback')][string]$Action = 'Apply',
        [string]$Injection = 'None',
        [string]$Frontend = $Case.Frontend,
        [string]$Backend = $Case.Backend,
        [string]$Stage = $Case.Stage,
        [string]$Transaction = $Case.Transaction,
        [string]$Observation = $Case.Observation
    )
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-Argument $UpgradeScript),
        '-Mode', 'RepairMixedIsolated',
        '-IsolationRoot', (Quote-Argument $Case.Root),
        '-StagingRoot', (Quote-Argument $Stage),
        '-TransactionRoot', (Quote-Argument $Transaction),
        '-FrontendTarget', (Quote-Argument $Frontend),
        '-BackendTarget', (Quote-Argument $Backend),
        '-PreflightObservationPath', (Quote-Argument $Observation),
        '-IsolatedAction', $Action,
        '-MixedFixtureVariant', $Case.Variant,
        '-MixedFailureInjection', $Injection
    ) -join ' '
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.EnvironmentVariables['PATH'] = (Split-Path -Parent $GitBranchShim) + ';' + $startInfo.EnvironmentVariables['PATH']
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $json = $null
    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        try { $json = $stdout.Trim() | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "[$($Case.Name)] stdout was not one JSON document. stdout=$stdout stderr=$stderr" }
    }
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Json = $json; Stdout = $stdout; Stderr = $stderr }
}

function Assert-FailureThenRollback {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Injection
    )
    $case = New-MixedCase $Name
    $before = Get-TreeCanonical $case
    $result = Invoke-MixedProcess -Case $case -Injection $Injection
    Assert-True ($result.ExitCode -eq 5) "$Name did not fail with mixed repair exit 5. stderr=$($result.Stderr)"
    $rollback = Invoke-MixedProcess -Case $case -Action Rollback
    Assert-True ($rollback.ExitCode -eq 0 -and $rollback.Json.state -eq 'rolled_back') "$Name explicit rollback failed. stderr=$($rollback.Stderr)"
    Assert-True ((Get-TreeCanonical $case) -ceq $before) "$Name did not restore exact path/existence/length/SHA-256/mtime state."
}

function Assert-PrepareFailureZeroTargetWrites {
    param([string]$Name, [string]$Injection)
    $case = New-MixedCase $Name
    $before = Get-TreeCanonical $case
    $result = Invoke-MixedProcess -Case $case -Injection $Injection
    Assert-True ($result.ExitCode -eq 5) "$Name did not fail with mixed repair exit 5."
    Assert-True ((Get-TreeCanonical $case) -ceq $before) "$Name wrote target content before prepare completed."
}

function Assert-BoundaryRejectedWithoutWrites {
    param(
        [string]$Name,
        [string]$Frontend,
        [string]$Backend,
        [string]$Stage,
        [string]$Transaction,
        [string]$Observation
    )
    $case = New-MixedCase $Name
    if (-not $Frontend) { $Frontend = $case.Frontend }
    if (-not $Backend) { $Backend = $case.Backend }
    if (-not $Stage) { $Stage = $case.Stage }
    if (-not $Transaction) { $Transaction = $case.Transaction }
    if (-not $Observation) { $Observation = $case.Observation }
    $before = Get-TreeCanonical $case
    $result = Invoke-MixedProcess -Case $case -Frontend $Frontend -Backend $Backend -Stage $Stage -Transaction $Transaction -Observation $Observation
    Assert-True ($result.ExitCode -eq 5) "$Name boundary was not rejected."
    Assert-True ($result.Stderr -match 'UPGRADE_MIXED_BOUNDARY_FAIL') "$Name did not report a mixed boundary failure. stderr=$($result.Stderr)"
    Assert-True ((Get-TreeCanonical $case) -ceq $before) "$Name boundary rejection changed fake target/evidence."
    Assert-True (-not (Test-Path -LiteralPath $case.Stage) -and -not (Test-Path -LiteralPath $case.Transaction)) "$Name created staging or transaction evidence before boundary rejection."
}

$failure = $null
try {
    Assert-StrictTempPath $SuiteRoot
    Assert-StrictTempPath $OutsideRoot
    New-Item -ItemType Directory -Path $SuiteRoot -Force | Out-Null
    Initialize-BranchOnlyGitShim
    Assert-BranchOnlyGitShimContract
    $basisText = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\upgrade_formal_prepare.ps1') -Raw -Encoding UTF8
    Assert-True ($basisText -notmatch 'CheckpointApproved') 'Mixed fixture is connected to a helper that can bypass live origin/main coherence.'
    Assert-True ($basisText -match 'Assert-FormalPrepareMainBranch.+-FixtureMode \$FixtureMode') 'Mixed fixture lost the explicit fixture-only branch seam.'

    $success = New-MixedCase 'success'
    $beforeRecords = Get-TreeRecords $success
    $beforeCanonical = Get-TreeCanonical $success
    $beforeGuards = Get-GuardCanonical $success
    $expectedIds = Get-ExpectedSourceIds $success
    $successResult = Invoke-MixedProcess -Case $success
    Assert-True ($successResult.ExitCode -eq 0) "Success apply failed: $($successResult.Stderr)"
    $journal = $successResult.Json
    Assert-True ($journal.state -eq 'committed_pending_acceptance') 'Success did not stop at committed_pending_acceptance.'
    Assert-True ($journal.source_manifest.software_state_id -eq $expectedIds.Software) 'Software state ID is not independently recomputable.'
    Assert-True ($journal.source_manifest.evidence_state_id -eq $expectedIds.Evidence) 'Evidence state ID is not independently recomputable.'
    $replacePaths = @($journal.files | Where-Object { $_.action -eq 'replace' } | ForEach-Object { "$($_.side)/$($_.relative_path)" } | Sort-Object)
    Assert-True (($replacePaths -join ',') -eq 'Frontend/src/backend/adapter.py,Frontend/src/tray/tray_app.py') 'Base plan did not contain exactly the adapter and tray replaces.'
    Assert-True (@($journal.files | Where-Object { $_.action -eq 'verify_unchanged' }).Count -eq 24) 'Base plan did not contain 24 verify_unchanged records.'
    Assert-True ($journal.files.Count -eq 26 -and $journal.protected_preimage.Count -eq 2 -and $journal.versions.Count -eq 2) 'Full managed/protected preimage record counts are wrong.'
    Assert-True (@($journal.files | Where-Object { $_.package_path }).Count -eq 26 -and $journal.versions.Count -eq 2) 'Full managed/marker package record counts are wrong.'
    $SuccessEvidenceSummary = "software=$($journal.source_manifest.software_state_id) evidence=$($journal.source_manifest.evidence_state_id) preimage=26+4 package=26+2"
    $events = @($journal.events)
    $managedIndex = [Array]::IndexOf($events, 'managed-26-verified')
    $backendIndex = [Array]::IndexOf($events, 'marker:Backend')
    $frontendIndex = [Array]::IndexOf($events, 'marker:Frontend')
    Assert-True ($managedIndex -ge 0 -and $managedIndex -lt $backendIndex -and $backendIndex -lt $frontendIndex) 'Marker-last order was not managed verify -> Backend -> Frontend.'
    foreach ($record in @($journal.files | Where-Object { $_.action -eq 'verify_unchanged' })) {
        $key = "$($record.side)/$($record.relative_path)"
        $afterRecords = Get-TreeRecords $success
        Assert-True ($afterRecords[$key] -ceq $beforeRecords[$key]) "verify_unchanged record was rewritten: $key"
    }
    $targetAdapterBlob = (& git -C $RepoRoot hash-object -- $success.Adapter).Trim()
    $expectedTargetAdapterBlob = (& git -C $RepoRoot rev-parse "$TargetCommit`:Frontend/src/backend/adapter.py").Trim()
    Assert-True ($targetAdapterBlob -eq $expectedTargetAdapterBlob) 'Success adapter did not become the shared formal target package blob.'
    $targetTrayBlob = (& git -C $RepoRoot hash-object -- $success.Tray).Trim()
    Assert-True ($targetTrayBlob -eq $ExpectedTargetTrayBlob) 'Success tray did not become the ruled target package blob.'
    Assert-True ($journal.source_baseline_commit -eq $SourceCommit -and $journal.source_adapter_commit -eq $AdapterCommit) 'Journal did not preserve the source baseline and adapter override identities.'
    Assert-True ((Get-Content -LiteralPath $success.BackendMarker -Raw).Trim() -eq $TargetShort) 'Backend marker was not updated to the shared formal target short hash.'
    Assert-True ((Get-Content -LiteralPath $success.FrontendMarker -Raw).Trim() -eq $TargetShort) 'Frontend marker was not updated to the shared formal target short hash.'
    Assert-True ((Get-GuardCanonical $success) -ceq $beforeGuards) 'Success changed protected/unmanaged/registry evidence.'
    $successRollback = Invoke-MixedProcess -Case $success -Action Rollback
    Assert-True ($successRollback.ExitCode -eq 0 -and $successRollback.Json.state -eq 'rolled_back') "Pending-acceptance rollback failed. stderr=$($successRollback.Stderr)"
    Assert-True ((Get-TreeCanonical $success) -ceq $beforeCanonical) 'Pending-acceptance rollback did not restore the full mixed source tree exactly.'

    Assert-PrepareFailureZeroTargetWrites 'preimage-failure' 'Preimage'
    Assert-PrepareFailureZeroTargetWrites 'package-failure' 'Package'
    Assert-PrepareFailureZeroTargetWrites 'prepared-interruption' 'Prepare'
    Assert-FailureThenRollback 'adapter-before-replace' 'AdapterBeforeReplace'
    Assert-FailureThenRollback 'adapter-after-replace-before-journal' 'AdapterAfterReplace'
    Assert-FailureThenRollback 'backend-marker-after-replace' 'BackendMarkerAfterReplace'
    Assert-FailureThenRollback 'postcheck-failure' 'PostCheck'

    foreach ($variant in @('OriginallyAbsent', 'ExtraDelete')) {
        $case = New-MixedCase ("semantic-" + $variant.ToLowerInvariant()) $variant
        $before = Get-TreeCanonical $case
        $apply = Invoke-MixedProcess -Case $case
        Assert-True ($apply.ExitCode -eq 0) "$variant apply failed: $($apply.Stderr)"
        if ($variant -eq 'OriginallyAbsent') {
            Assert-True (Test-Path -LiteralPath (Join-Path $case.Frontend 'run_dev_ui.bat') -PathType Leaf) 'Originally absent package file was not added.'
        }
        else {
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $case.Frontend 'src\mixed-extra-delete.fixture'))) 'Extra delete was not applied.'
        }
        $rollback = Invoke-MixedProcess -Case $case -Action Rollback
        Assert-True ($rollback.ExitCode -eq 0) "$variant rollback failed: $($rollback.Stderr)"
        Assert-True ((Get-TreeCanonical $case) -ceq $before) "$variant exact rollback semantics failed."
    }

    $unknown = New-MixedCase 'unknown-hash-indeterminate'
    $crash = Invoke-MixedProcess -Case $unknown -Injection AdapterAfterReplace
    Assert-True ($crash.ExitCode -eq 5) 'Unknown-hash setup did not stop after adapter replace.'
    'third-party-unknown-content' | Set-Content -LiteralPath $unknown.Adapter -Encoding UTF8
    [System.IO.File]::SetLastWriteTimeUtc($unknown.Adapter, $FixedTime)
    $beforeUnknownRollback = Get-TreeCanonical $unknown
    $unknownRollback = Invoke-MixedProcess -Case $unknown -Action Rollback
    Assert-True ($unknownRollback.ExitCode -eq 5 -and $unknownRollback.Stderr -match 'UPGRADE_MIXED_INDETERMINATE') 'Unknown hash did not stop for human adjudication.'
    Assert-True ((Get-TreeCanonical $unknown) -ceq $beforeUnknownRollback) 'Indeterminate rollback wrote target content.'

    New-Item -ItemType Directory -Path $OutsideRoot -Force | Out-Null
    Assert-BoundaryRejectedWithoutWrites 'path-escape' -Frontend $OutsideRoot
    Assert-BoundaryRejectedWithoutWrites 'repo-target' -Frontend $RepoRoot
    Assert-BoundaryRejectedWithoutWrites 'formal-target' -Frontend (Join-Path $env:LOCALAPPDATA 'LaplaceSentry')
    $overlap = New-MixedCase 'overlap-reject'
    $overlapBefore = Get-TreeCanonical $overlap
    $overlapResult = Invoke-MixedProcess -Case $overlap -Stage (Join-Path $overlap.Frontend 'stage')
    Assert-True ($overlapResult.ExitCode -eq 5 -and $overlapResult.Stderr -match 'UPGRADE_MIXED_BOUNDARY_FAIL') 'Target/staging overlap was not rejected.'
    Assert-True ((Get-TreeCanonical $overlap) -ceq $overlapBefore) 'Overlap rejection changed target state.'

    $reparse = New-MixedCase 'reparse-reject'
    $junctionTarget = Join-Path $reparse.Root 'junction-target'
    $JunctionPath = Join-Path $reparse.Root 'junction-staging'
    New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
    New-Item -ItemType Junction -Path $JunctionPath -Target $junctionTarget | Out-Null
    $reparseBefore = Get-TreeCanonical $reparse
    $reparseResult = Invoke-MixedProcess -Case $reparse -Stage $JunctionPath
    Assert-True ($reparseResult.ExitCode -eq 5 -and $reparseResult.Stderr -match 'Reparse/junction ambiguity') 'Reparse ambiguity was not rejected.'
    Assert-True ((Get-TreeCanonical $reparse) -ceq $reparseBefore) 'Reparse rejection changed target state.'
}
catch {
    $failure = $_
}
finally {
    try {
        if ($JunctionPath -and (Test-Path -LiteralPath $JunctionPath)) { Remove-Item -LiteralPath $JunctionPath -Force }
        if (Test-Path -LiteralPath $OutsideRoot) { Remove-TestTree $OutsideRoot }
        if (Test-Path -LiteralPath $SuiteRoot) { Remove-TestTree $SuiteRoot }
    }
    catch {
        if ($null -eq $failure) { $failure = $_ }
    }
}

if ((Test-Path -LiteralPath $SuiteRoot) -or (Test-Path -LiteralPath $OutsideRoot)) {
    if ($null -eq $failure) { $failure = [System.Exception]::new('[ASSERT_FAIL] TEMP residue remains after cleanup.') }
}
if ($failure) {
    Write-Error $failure
    exit 1
}
Write-Output "[PASS] mixed repair proved deterministic state IDs, prepare gates, adapter and tray managed-file replacements, marker-last, crash reconciliation, semantic rollback, guard immutability, boundary rejection, and TEMP residue 0. $SuccessEvidenceSummary"
exit 0
