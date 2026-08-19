[CmdletBinding()]
param()

<#
.SYNOPSIS
Proves the internal formal-write boundary plus strict-TEMP install/recovery behavior with isolated transactions.

.DESCRIPTION
Purpose: exercise explicit transaction validation, hard-locked formal paths, a single upgrade lock, durable single-journal progress, runtime rechecks, strict-TEMP install/recovery, marker-last completion, metadata contracts, injected-failure rollback, interrupted reentry, indeterminate stops, protected-data safety, and zero-formal-write behavior.
Inputs: fixed Git objects plus generated mixed Frontend/Backend targets, prepared transactions, and observation JSON below system TEMP.
Outputs: one PASS/FAIL result; all validation/install/recovery fixture evidence is removed before exit.
SSOT Output: process exit code; zero means every validation, install, recovery, boundary, and cleanup assertion passed.
Exit codes: 0 pass, 1 assertion, boundary, script, or cleanup failure.
SKIP conditions: none.
FAIL conditions: any wrong exit/result/tag/order/restoration, protected-data mutation, formal-boundary change, or TEMP residue.
Order-sensitive checks: validation remains read-only; fixture writes begin only after eligibility, and every failure/reentry assertion compares current targets with the sealed preimage/package evidence.
Side effects: creates, mutates, and removes only verified strict children of system TEMP and performs read-only formal-boundary observations; never invokes live prepare/apply/rollback, upgrade.bat, Git writes, processes, registry, or runtime changes.
#>

# 這支腳本在做什麼：用 TEMP prepared transaction 先驗票，再證明正常安裝、故障還原與突然中止後重建。
# 這支腳本不做什麼：不跑 live prepare/apply/rollback、不刪正式交易、不改 Git／程序／registry／正式副本。
# 常改區塊：驗票拒絕案例、安裝順序、故障矩陣、重入停損與使用者資料斷言。
# 不要亂動的區塊：明確 transaction root、正式邊界前後 fingerprint、嚴格 TEMP 清理與零殘留。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$UpgradeScript = Join-Path $RepoRoot 'scripts\upgrade.ps1'
$FormalApplyScript = Join-Path $RepoRoot 'scripts\upgrade_formal_apply.ps1'
$UpgradeBat = Join-Path $RepoRoot 'upgrade.bat'
$TempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$SuiteRoot = Join-Path $TempBase ('LaplaceSentryFormalApplySmoke-' + [Guid]::NewGuid().ToString('N'))
$OutsideRoot = Join-Path $TempBase ('LaplaceSentryFormalApplyOutside-' + [Guid]::NewGuid().ToString('N'))
$TemplateRoot = Join-Path $SuiteRoot '_template'
$GitBranchShim = Join-Path $SuiteRoot '_git-branch-shim\git.cmd'
$RealGitExe = (Get-Command git.exe -ErrorAction Stop).Source
$FormalFrontend = Join-Path $env:LOCALAPPDATA 'LaplaceSentry'
$FormalBackendLinux = '/home/serpal/.laplace_sentry_backend'
$FormalTransactions = Join-Path $env:LOCALAPPDATA 'LaplaceSentryUpgrade\transactions'
# 在受限 scope 直接讀 PrepareFormal 的正式目標來源，避免 apply smoke 自帶第二份 target 或污染測試 scope。
$TargetCommit = & { . (Join-Path $RepoRoot 'scripts\upgrade_formal_prepare.ps1'); $FormalUpgradeTargetCommit }
$AdapterCommit = '4f228ae5f31754aa43a918274e3b542b6f0a2144'
$SourceCommit = '971ba498d613c2bb20d46e14855cc0b0a326602a'
$ExpectedAdapterBlob = 'ad49188e2f54c00245f54744e1413cfe83e8d867'
$ExpectedSourceTrayBlob = '13577b3bfa63af7ba320f0a410545503c704b4c2'
$SourceMarker = '1e7bc2b'
$FixedTime = [DateTime]::Parse('2024-01-02T03:04:05.0000000Z', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
$FrontendAllowlist = @('assets', 'src', 'requirements.txt', 'run_ui.bat', 'run_ui.vbs', 'run_dev_ui.bat')
$BackendAllowlist = @('main.py', 'requirements.txt', 'src')
$JunctionPath = $null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "[ASSERT_FAIL] $Message" }
}

function Assert-StrictTempPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    Assert-True ($resolved.StartsWith($TempBase + '\', [StringComparison]::OrdinalIgnoreCase)) "Path escaped system TEMP: $resolved"
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
    $specs = @($FrontendAllowlist | ForEach-Object { 'Frontend/' + $_ }) + @($BackendAllowlist | ForEach-Object { 'Backend/' + $_ })
    $paths = @(& git -C $RepoRoot ls-tree -r --name-only $TargetCommit -- @specs)
    Assert-True ($LASTEXITCODE -eq 0) 'Unable to enumerate target package paths.'
    return @($paths | Where-Object { $_ -and $_ -notmatch '(^|/)(__pycache__|\.venv)(/|$)' -and $_ -notmatch '\.pyc$' } | Sort-Object -Unique)
}

function Export-CommitTree {
    param([string]$Commit, [string[]]$PathSpecs, [string]$Destination, [string]$WorkRoot)
    New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
    $archive = Join-Path $WorkRoot 'tree.zip'
    & git -C $RepoRoot archive --format=zip "--output=$archive" $Commit -- @PathSpecs
    Assert-True ($LASTEXITCODE -eq 0) "git archive failed for $Commit."
    Expand-Archive -LiteralPath $archive -DestinationPath $Destination -Force
    Remove-Item -LiteralPath $archive -Force
}

function Initialize-ApplyTemplate {
    $build = Join-Path $TemplateRoot 'fixture-build'
    $tree = Join-Path $build 'source'
    $oldTree = Join-Path $build 'old-adapter'
    New-Item -ItemType Directory -Path $TemplateRoot -Force | Out-Null
    $specs = @($FrontendAllowlist | ForEach-Object { 'Frontend/' + $_ }) + @($BackendAllowlist | ForEach-Object { 'Backend/' + $_ })
    Export-CommitTree -Commit $SourceCommit -PathSpecs $specs -Destination $tree -WorkRoot (Join-Path $build 'source-archive')
    Export-CommitTree -Commit $AdapterCommit -PathSpecs @('Frontend/src/backend/adapter.py') -Destination $oldTree -WorkRoot (Join-Path $build 'old-archive')
    $frontend = Join-Path $TemplateRoot 'frontend-target'
    $backend = Join-Path $TemplateRoot 'backend-target'
    Move-Item -LiteralPath (Join-Path $tree 'Frontend') -Destination $frontend
    Move-Item -LiteralPath (Join-Path $tree 'Backend') -Destination $backend
    Copy-Item -LiteralPath (Join-Path $oldTree 'Frontend\src\backend\adapter.py') -Destination (Join-Path $frontend 'src\backend\adapter.py') -Force
    Assert-True ((& git -C $RepoRoot hash-object -- (Join-Path $frontend 'src\tray\tray_app.py')).Trim() -eq $ExpectedSourceTrayBlob) 'Apply template tray is not the ruled source-baseline blob.'
    Assert-True ((& git -C $RepoRoot hash-object -- (Join-Path $frontend 'src\backend\adapter.py')).Trim() -eq $ExpectedAdapterBlob) 'Apply template adapter is not the ruled override blob.'
    Remove-TestTree $build
    New-Item -ItemType Directory -Path (Join-Path $backend 'data') -Force | Out-Null
    "[General]`r`neye_size=480" | Set-Content -LiteralPath (Join-Path $frontend 'sentry_config.ini') -Encoding UTF8
    '[{"uuid":"fixture-project","name":"must-survive"}]' | Set-Content -LiteralPath (Join-Path $backend 'data\projects.json') -Encoding UTF8
    $SourceMarker | Set-Content -LiteralPath (Join-Path $frontend 'version.txt') -Encoding ASCII -NoNewline
    $SourceMarker | Set-Content -LiteralPath (Join-Path $backend 'version.txt') -Encoding ASCII -NoNewline
    [ordered]@{
        source_dirty = $false; tracked_deletions = @(); requirements_changes = @(); force_non_ancestor = $false
        protected_unreadable = @(); ambiguous_runtime = @(); lock_exists = $false; ui = @(); daemon = @(); workers = @()
        registry = @([ordered]@{ pid = 114348; uuid = 'fixture-stale'; proc_exists = $false; owned = $false; uuid_matches = $false; ambiguous = $false })
        transaction_acl_ok = $true; transaction_owner_ok = $true; free_bytes = [int64](4GB)
        fixture_backend_mode = '755'; fixture_backend_uid = 1000; fixture_backend_gid = 1000
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $TemplateRoot 'observation.json') -Encoding UTF8
    foreach ($file in @(Get-ChildItem -LiteralPath $frontend, $backend -Recurse -File -Force)) { [IO.File]::SetLastWriteTimeUtc($file.FullName, $FixedTime) }
    [IO.File]::SetLastWriteTimeUtc((Join-Path $TemplateRoot 'observation.json'), $FixedTime)
}

function New-ApplyCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateSet('Base', 'OriginallyAbsent', 'ExtraDelete')][string]$Variant = 'Base'
    )
    $root = Join-Path $SuiteRoot $Name
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $TemplateRoot 'frontend-target') -Destination (Join-Path $root 'frontend-target') -Recurse
    Copy-Item -LiteralPath (Join-Path $TemplateRoot 'backend-target') -Destination (Join-Path $root 'backend-target') -Recurse
    Copy-Item -LiteralPath (Join-Path $TemplateRoot 'observation.json') -Destination (Join-Path $root 'observation.json')
    if ($Variant -eq 'OriginallyAbsent') {
        Remove-Item -LiteralPath (Join-Path $root 'frontend-target\run_dev_ui.bat') -Force
    }
    elseif ($Variant -eq 'ExtraDelete') {
        'fixture extra scheduled for deletion' | Set-Content -LiteralPath (Join-Path $root 'frontend-target\src\mixed-extra-delete.fixture') -Encoding UTF8
    }
    $case = [pscustomobject]@{
        Name = $Name; Variant = $Variant; Root = $root
        Frontend = Join-Path $root 'frontend-target'; Backend = Join-Path $root 'backend-target'
        Transactions = Join-Path $root 'transactions'; Observation = Join-Path $root 'observation.json'
    }
    Add-Member -InputObject $case -NotePropertyName Adapter -NotePropertyValue (Join-Path $case.Frontend 'src\backend\adapter.py')
    Add-Member -InputObject $case -NotePropertyName Tray -NotePropertyValue (Join-Path $case.Frontend 'src\tray\tray_app.py')
    Add-Member -InputObject $case -NotePropertyName Config -NotePropertyValue (Join-Path $case.Frontend 'sentry_config.ini')
    Add-Member -InputObject $case -NotePropertyName Projects -NotePropertyValue (Join-Path $case.Backend 'data\projects.json')
    foreach ($file in @(Get-ChildItem -LiteralPath $case.Frontend, $case.Backend -Recurse -File -Force)) { [IO.File]::SetLastWriteTimeUtc($file.FullName, $FixedTime) }
    [IO.File]::SetLastWriteTimeUtc($case.Observation, $FixedTime)
    return $case
}

function Write-CaseObservation {
    param($Case, $Observation)
    $Observation | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Case.Observation -Encoding UTF8
    [IO.File]::SetLastWriteTimeUtc($Case.Observation, $FixedTime)
}

function Invoke-UpgradeProcess {
    param($Case, [string]$Mode, [string]$TransactionRoot, [string]$FormalFailure = 'None')
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-Argument $UpgradeScript),
        '-Mode', $Mode,
        '-IsolationRoot', (Quote-Argument $Case.Root),
        '-TransactionRoot', (Quote-Argument $TransactionRoot),
        '-FrontendTarget', (Quote-Argument $Case.Frontend),
        '-BackendTarget', (Quote-Argument $Case.Backend),
        '-PreflightObservationPath', (Quote-Argument $Case.Observation),
        '-MixedFixtureVariant', $Case.Variant,
        '-FormalApplyFailureInjection', $FormalFailure
    ) -join ' '
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'powershell.exe'; $startInfo.Arguments = $arguments; $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true; $startInfo.RedirectStandardError = $true; $startInfo.CreateNoWindow = $true
    $startInfo.EnvironmentVariables['PATH'] = (Split-Path -Parent $GitBranchShim) + ';' + $startInfo.EnvironmentVariables['PATH']
    $process = [Diagnostics.Process]::Start($startInfo)
    $stdout = $process.StandardOutput.ReadToEnd(); $stderr = $process.StandardError.ReadToEnd(); $process.WaitForExit()
    $json = $null
    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        try { $json = $stdout.Trim() | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "[$($Case.Name)/$Mode] stdout was not one JSON document. stdout=$stdout stderr=$stderr" }
    }
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Json = $json; Stdout = $stdout; Stderr = $stderr }
}

function New-PreparedCase {
    param([string]$Name, [ValidateSet('Base', 'OriginallyAbsent', 'ExtraDelete')][string]$Variant = 'Base')
    $case = New-ApplyCase -Name $Name -Variant $Variant
    $prepared = Invoke-UpgradeProcess -Case $case -Mode 'PrepareFormal' -TransactionRoot $case.Transactions
    Assert-True ($prepared.ExitCode -eq 0 -and $prepared.Json.result -eq 'prepared') "[$Name] prepare setup failed. stderr=$($prepared.Stderr)"
    $directories = @(Get-ChildItem -LiteralPath $case.Transactions -Directory -Force)
    Assert-True ($directories.Count -eq 1) "[$Name] prepare did not create exactly one transaction."
    Add-Member -InputObject $case -NotePropertyName Transaction -NotePropertyValue $directories[0].FullName
    Add-Member -InputObject $case -NotePropertyName Journal -NotePropertyValue (Join-Path $directories[0].FullName 'transaction-journal.json')
    return $case
}

function Save-PreparedBaseline {
    param($Case, [string]$Label = 'base')
    $baseline = Join-Path $OutsideRoot "prepared-baseline-$Label"
    New-Item -ItemType Directory -Path $baseline -Force | Out-Null
    Copy-Item -LiteralPath $Case.Frontend -Destination (Join-Path $baseline 'frontend-target') -Recurse
    Copy-Item -LiteralPath $Case.Backend -Destination (Join-Path $baseline 'backend-target') -Recurse
    Copy-Item -LiteralPath $Case.Transactions -Destination (Join-Path $baseline 'transactions') -Recurse
    Copy-Item -LiteralPath $Case.Observation -Destination (Join-Path $baseline 'observation.json')
    return $baseline
}

function Restore-PreparedBaseline {
    param($Case, [string]$Baseline, [string]$Name)
    foreach ($path in @($Case.Frontend, $Case.Backend, $Case.Transactions)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
    if (Test-Path -LiteralPath $Case.Observation) { Remove-Item -LiteralPath $Case.Observation -Force }
    Copy-Item -LiteralPath (Join-Path $Baseline 'frontend-target') -Destination $Case.Frontend -Recurse
    Copy-Item -LiteralPath (Join-Path $Baseline 'backend-target') -Destination $Case.Backend -Recurse
    Copy-Item -LiteralPath (Join-Path $Baseline 'transactions') -Destination $Case.Transactions -Recurse
    Copy-Item -LiteralPath (Join-Path $Baseline 'observation.json') -Destination $Case.Observation
    $Case.Name = $Name
    Assert-True (Test-Path -LiteralPath $Case.Transaction -PathType Container) "[$Name] baseline restore lost the selected transaction."
}

function Get-TreeCanonical {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'ABSENT' }
    $lines = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($Path.Length).TrimStart('\').Replace('\', '/')
        $lines += "$relative|$($file.Length)|$($file.LastWriteTimeUtc.ToString('o'))|$($file.Attributes)|$(Get-Sha $file.FullName)"
    }
    return @($lines) -join "`n"
}

function Get-CaseTargetCanonical {
    param($Case)
    return (Get-TreeCanonical $Case.Frontend) + "`n---BACKEND---`n" + (Get-TreeCanonical $Case.Backend)
}

function Get-FormalBoundaryCanonical {
    $parts = @()
    foreach ($gitPath in Get-ExpectedManagedPaths) {
        $side = if ($gitPath.StartsWith('Frontend/')) { 'Frontend' } else { 'Backend' }
        $relative = $gitPath.Substring($side.Length + 1)
        if ($side -eq 'Backend') {
            $linux = "$FormalBackendLinux/$relative"
            $stat = @(& wsl.exe -d Ubuntu --exec stat -c '%s|%Y' -- $linux 2>$null)
            if ($LASTEXITCODE -eq 0 -and $stat.Count -eq 1) {
                $hash = @(& wsl.exe -d Ubuntu --exec sha256sum -- $linux 2>$null)
                Assert-True ($LASTEXITCODE -eq 0 -and $hash.Count -eq 1) "Unable to hash formal backend path: $linux"
                $parts += "$gitPath|$($stat[0])|$((($hash[0] -split '\s+')[0]).ToUpperInvariant())"
            } else { $parts += "$gitPath|ABSENT" }
        }
        else {
            $path = Join-Path $FormalFrontend $relative.Replace('/', '\')
            if (Test-Path -LiteralPath $path -PathType Leaf) { $parts += "$gitPath|$((Get-Item $path).Length)|$(Get-Sha $path)" }
            else { $parts += "$gitPath|ABSENT" }
        }
    }
    foreach ($spec in @(
        @('Frontend/version.txt', (Join-Path $FormalFrontend 'version.txt')),
        @('Frontend/sentry_config.ini', (Join-Path $FormalFrontend 'sentry_config.ini'))
    )) {
        if (Test-Path -LiteralPath $spec[1] -PathType Leaf) { $parts += "$($spec[0])|$((Get-Item $spec[1]).Length)|$(Get-Sha $spec[1])" }
        else { $parts += "$($spec[0])|ABSENT" }
    }
    foreach ($relative in @('version.txt', 'data/projects.json')) {
        $linux = "$FormalBackendLinux/$relative"
        $stat = @(& wsl.exe -d Ubuntu --exec stat -c '%s|%Y' -- $linux 2>$null)
        if ($LASTEXITCODE -eq 0 -and $stat.Count -eq 1) {
            $hash = @(& wsl.exe -d Ubuntu --exec sha256sum -- $linux 2>$null)
            Assert-True ($LASTEXITCODE -eq 0 -and $hash.Count -eq 1) "Unable to hash formal backend witness: $linux"
            $parts += "Backend/$relative|$($stat[0])|$((($hash[0] -split '\s+')[0]).ToUpperInvariant())"
        } else { $parts += "Backend/$relative|ABSENT" }
    }
    $parts += "formal-transactions|$(Get-TreeCanonical $FormalTransactions)"
    return @($parts | Sort-Object) -join "`n"
}

function Assert-ValidationResult {
    param($Case, [string]$TransactionRoot, [int]$ExitCode, [string]$Result, [string]$Tag)
    $targetBefore = Get-CaseTargetCanonical $Case
    $transactionBefore = Get-TreeCanonical $TransactionRoot
    $actual = Invoke-UpgradeProcess -Case $Case -Mode 'ValidateFormalApply' -TransactionRoot $TransactionRoot
    Assert-True ($actual.ExitCode -eq $ExitCode) "[$($Case.Name)] expected exit $ExitCode, got $($actual.ExitCode). stderr=$($actual.Stderr)"
    Assert-True ($actual.Json.result -eq $Result -and [int]$actual.Json.formal_target_write_count -eq 0) "[$($Case.Name)] wrong result or write count."
    if ($Tag) { Assert-True (@($actual.Json.failures.tag) -contains $Tag) "[$($Case.Name)] expected rejection tag $Tag. stdout=$($actual.Stdout)" }
    Assert-True ((Get-CaseTargetCanonical $Case) -ceq $targetBefore) "[$($Case.Name)] validation changed fixture targets."
    Assert-True ((Get-TreeCanonical $TransactionRoot) -ceq $transactionBefore) "[$($Case.Name)] validation changed transaction evidence."
    return $actual
}

function Read-CaseJournal {
    param($Case)
    return Get-Content -LiteralPath $Case.Journal -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
}

function Get-ProtectedCanonical {
    param($Case)
    $parts = @()
    foreach ($path in @($Case.Config, $Case.Projects)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $item = Get-Item -LiteralPath $path -Force
            $parts += "$path|$($item.Length)|$($item.LastWriteTimeUtc.ToString('o'))|$($item.Attributes)|$(Get-Sha $path)"
        }
        else { $parts += "$path|ABSENT" }
    }
    return $parts -join "`n"
}

function Assert-CaseRestored {
    param($Case, [string]$Before, [string]$ProtectedBefore, [string]$Label)
    Assert-True ((Get-CaseTargetCanonical $Case) -ceq $Before) "[$Label] targets did not return to the exact preimage."
    Assert-True ((Get-ProtectedCanonical $Case) -ceq $ProtectedBefore) "[$Label] protected data changed."
    $journal = Read-CaseJournal $Case
    Assert-True ($journal.result -eq 'rolled_back' -and $journal.state -in @('rolled_back', 'rolled_back_after_failure')) "[$Label] journal did not record rolled_back."
    Assert-True ($journal.fixture_apply.execution_scope -eq 'fixture' -and [int]$journal.fixture_apply.formal_target_write_count -eq 0) "[$Label] crossed the formal execution scope."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $Case.Root 'formal-upgrade.lock'))) "[$Label] single upgrade lock was not released."
}

function Assert-CaseInstalledPendingAcceptance {
    param($Case, [string]$ProtectedBefore, [string]$Label)
    $journal = Read-CaseJournal $Case
    Assert-True ($journal.state -eq 'installed_pending_acceptance' -and $journal.result -eq 'installed_pending_acceptance') "[$Label] did not stop at installed_pending_acceptance."
    Assert-True ($journal.fixture_apply.execution_scope -eq 'fixture' -and [int]$journal.fixture_apply.formal_target_write_count -eq 0) "[$Label] crossed the formal execution scope."
    Assert-True ($journal.fixture_apply.upgrade_lock_path -eq (Join-Path $Case.Root 'formal-upgrade.lock')) "[$Label] journal did not bind the isolated single upgrade lock."
    Assert-True (-not (Test-Path -LiteralPath $journal.fixture_apply.upgrade_lock_path)) "[$Label] single upgrade lock was not released."
    Assert-True ((@($journal.fixture_apply.runtime_checkpoints) -join ',') -ceq 'after-upgrade-lock,before-first-target-write,before-version-markers') "[$Label] runtime checkpoints were incomplete or out of order."
    Assert-True ([bool]$journal.fixture_apply.journal_durable_before_first_write) "[$Label] journal durability was not proved before the first write."
    Assert-True ($journal.fixture_apply.metadata_contract.windows -eq 'content+existence+mtime+attributes+sddl' -and $journal.fixture_apply.metadata_contract.wsl -eq 'content+existence+mtime+uid+gid+mode' -and $journal.fixture_apply.metadata_contract.protected -eq 'observe-only-never-restored') "[$Label] metadata contract drifted."
    $journalFiles = @(Get-ChildItem -LiteralPath $Case.Transaction -Recurse -File -Force | Where-Object Name -eq 'transaction-journal.json')
    Assert-True ($journalFiles.Count -eq 1 -and $journalFiles[0].FullName -eq $Case.Journal) "[$Label] transaction did not use exactly one progress journal."
    Assert-True ((Get-ProtectedCanonical $Case) -ceq $ProtectedBefore) "[$Label] protected data changed during install."
    $records = @($journal.fixture_apply.files) + @($journal.fixture_apply.markers)
    foreach ($record in $records) {
        if ($record.action -eq 'delete') {
            Assert-True (-not (Test-Path -LiteralPath $record.target_path)) "[$Label] delete action still exists: $($record.key)"
        }
        else {
            Assert-True ((Test-Path -LiteralPath $record.target_path -PathType Leaf) -and (Get-Sha $record.target_path) -eq $record.package_sha256) "[$Label] package content mismatch: $($record.key)"
        }
    }
    Assert-True ((@($journal.fixture_apply.marker_order) -join ',') -ceq 'Backend/version.txt,Frontend/version.txt') "[$Label] marker order was not Backend then Frontend."
    $writeOrder = @($journal.fixture_apply.write_order)
    Assert-True ($writeOrder.Count -ge 2) "[$Label] write order is missing version marker writes."
    $writeTail = @($writeOrder[$writeOrder.Count - 2], $writeOrder[$writeOrder.Count - 1])
    Assert-True (($writeTail -join ',') -ceq 'Backend/version.txt,Frontend/version.txt') "[$Label] version markers were not the final writes."
    Assert-True (@($journal.fixture_apply.events) -contains 'all-general-files-verified-before-markers') "[$Label] lacks the general-files-before-markers proof."
    $events = @($journal.fixture_apply.events)
    $durableIndex = [Array]::IndexOf($events, 'journal-durable-before-first-target-write')
    $firstWriteIndex = -1
    for ($index = 0; $index -lt $events.Count; $index++) {
        if ([string]$events[$index] -like 'before-write:*') { $firstWriteIndex = $index; break }
    }
    Assert-True ($durableIndex -ge 0 -and $firstWriteIndex -gt $durableIndex) "[$Label] first target write preceded durable journal proof."
}

function Invoke-FailureRollbackCase {
    param($Case, [string]$Baseline, [string]$Failure)
    Restore-PreparedBaseline -Case $Case -Baseline $Baseline -Name "failure-$Failure"
    $before = Get-CaseTargetCanonical $Case
    $protected = Get-ProtectedCanonical $Case
    $actual = Invoke-UpgradeProcess -Case $Case -Mode 'ApplyFormalFixture' -TransactionRoot $Case.Transaction -FormalFailure $Failure
    Assert-True ($actual.ExitCode -eq 0 -and $actual.Json.result -eq 'rolled_back') "[$Failure] apply failure did not auto-rollback. stdout=$($actual.Stdout) stderr=$($actual.Stderr)"
    Assert-CaseRestored -Case $Case -Before $before -ProtectedBefore $protected -Label $Failure
}

try {
    New-Item -ItemType Directory -Path $SuiteRoot, $OutsideRoot -Force | Out-Null
    Initialize-BranchOnlyGitShim
    Assert-BranchOnlyGitShimContract
    $basisText = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\upgrade_formal_prepare.ps1') -Raw -Encoding UTF8
    Assert-True ($basisText -notmatch 'CheckpointApproved') 'Formal apply fixture is connected to a helper that can bypass live origin/main coherence.'
    Assert-True ($basisText -match 'Assert-FormalPrepareMainBranch.+-FixtureMode \$FixtureMode') 'Formal apply fixture lost the explicit fixture-only branch seam.'
    $formalBefore = Get-FormalBoundaryCanonical
    Initialize-ApplyTemplate

    $positive = New-PreparedCase 'eligible'
    $baseline = Save-PreparedBaseline -Case $positive
    $positiveResult = Assert-ValidationResult -Case $positive -TransactionRoot $positive.Transaction -ExitCode 0 -Result 'eligible' -Tag ''
    Assert-True ($positiveResult.Json.eligible -and [double]$positiveResult.Json.age_seconds -ge 0 -and [double]$positiveResult.Json.age_seconds -le 1800) 'Fresh prepared transaction was not eligible within the fixed age.'
    Assert-True (@($positiveResult.Json.checks | Where-Object status -eq 'pass').Count -ge 7) 'Eligible result lacks traceable pass checks.'
    Assert-True ((& git -C $RepoRoot hash-object -- $positive.Tray).Trim() -eq $ExpectedSourceTrayBlob) 'Eligible transaction source tray is not the ruled baseline blob.'
    Assert-True ((& git -C $RepoRoot hash-object -- $positive.Adapter).Trim() -eq $ExpectedAdapterBlob) 'Eligible transaction source adapter is not the ruled override blob.'

    Restore-PreparedBaseline -Case $positive -Baseline $baseline -Name 'wrong-root'
    [void](Assert-ValidationResult -Case $positive -TransactionRoot $positive.Transactions -ExitCode 7 -Result 'rejected' -Tag '[UPGRADE_APPLY_TRANSACTION_FAIL]')

    Restore-PreparedBaseline -Case $positive -Baseline $baseline -Name 'wrong-id'
    $journal = Get-Content -LiteralPath $positive.Journal -Raw -Encoding UTF8 | ConvertFrom-Json
    $journal.transaction_id = '20000101T0000000000000Z-' + ('0' * 32)
    $journal | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $positive.Journal -Encoding UTF8
    [void](Assert-ValidationResult -Case $positive -TransactionRoot $positive.Transaction -ExitCode 7 -Result 'rejected' -Tag '[UPGRADE_APPLY_TRANSACTION_FAIL]')

    Restore-PreparedBaseline -Case $positive -Baseline $baseline -Name 'stale'
    $journal = Get-Content -LiteralPath $positive.Journal -Raw -Encoding UTF8 | ConvertFrom-Json
    $journal.created_at_utc = [DateTime]::UtcNow.AddMinutes(-31).ToString('o')
    $journal | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $positive.Journal -Encoding UTF8
    [void](Assert-ValidationResult -Case $positive -TransactionRoot $positive.Transaction -ExitCode 7 -Result 'rejected' -Tag '[UPGRADE_APPLY_AGE_FAIL]')

    Restore-PreparedBaseline -Case $positive -Baseline $baseline -Name 'repo-drift'
    $journal = Get-Content -LiteralPath $positive.Journal -Raw -Encoding UTF8 | ConvertFrom-Json
    $journal.repo_head = 'ffffffffffffffffffffffffffffffffffffffff'
    $journal | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $positive.Journal -Encoding UTF8
    [void](Assert-ValidationResult -Case $positive -TransactionRoot $positive.Transaction -ExitCode 7 -Result 'rejected' -Tag '[UPGRADE_APPLY_REPO_FAIL]')

    Restore-PreparedBaseline -Case $positive -Baseline $baseline -Name 'manifest-tamper'
    $journal = Get-Content -LiteralPath $positive.Journal -Raw -Encoding UTF8 | ConvertFrom-Json
    'tamper' | Add-Content -LiteralPath $journal.manifests.source.path -Encoding UTF8
    [void](Assert-ValidationResult -Case $positive -TransactionRoot $positive.Transaction -ExitCode 7 -Result 'rejected' -Tag '[UPGRADE_APPLY_EVIDENCE_FAIL]')

    Restore-PreparedBaseline -Case $positive -Baseline $baseline -Name 'artifact-tamper'
    $journal = Get-Content -LiteralPath $positive.Journal -Raw -Encoding UTF8 | ConvertFrom-Json
    $package = Get-Content -LiteralPath $journal.manifests.package.path -Raw -Encoding UTF8 | ConvertFrom-Json
    'tamper' | Add-Content -LiteralPath $package.records[0].artifact_path -Encoding UTF8
    [void](Assert-ValidationResult -Case $positive -TransactionRoot $positive.Transaction -ExitCode 7 -Result 'rejected' -Tag '[UPGRADE_APPLY_EVIDENCE_FAIL]')

    Restore-PreparedBaseline -Case $positive -Baseline $baseline -Name 'target-drift'
    'target-drift' | Add-Content -LiteralPath $positive.Adapter -Encoding UTF8
    [void](Assert-ValidationResult -Case $positive -TransactionRoot $positive.Transaction -ExitCode 7 -Result 'rejected' -Tag '[UPGRADE_APPLY_TARGET_FAIL]')

    Restore-PreparedBaseline -Case $positive -Baseline $baseline -Name 'tray-target-drift'
    'tray-target-drift' | Add-Content -LiteralPath $positive.Tray -Encoding UTF8
    [void](Assert-ValidationResult -Case $positive -TransactionRoot $positive.Transaction -ExitCode 7 -Result 'rejected' -Tag '[UPGRADE_APPLY_TARGET_FAIL]')

    Restore-PreparedBaseline -Case $positive -Baseline $baseline -Name 'protected-drift'
    'protected-drift' | Add-Content -LiteralPath $positive.Projects -Encoding UTF8
    [void](Assert-ValidationResult -Case $positive -TransactionRoot $positive.Transaction -ExitCode 7 -Result 'rejected' -Tag '[UPGRADE_APPLY_PROTECTED_FAIL]')

    Restore-PreparedBaseline -Case $positive -Baseline $baseline -Name 'runtime-drift'
    $observation = Get-Content -LiteralPath $positive.Observation -Raw -Encoding UTF8 | ConvertFrom-Json
    $observation.ui = @([pscustomobject]@{ pid = 12345 })
    Write-CaseObservation -Case $positive -Observation $observation
    [void](Assert-ValidationResult -Case $positive -TransactionRoot $positive.Transaction -ExitCode 7 -Result 'rejected' -Tag '[UPGRADE_APPLY_RUNTIME_FAIL]')

    Restore-PreparedBaseline -Case $positive -Baseline $baseline -Name 'lock-drift'
    $observation = Get-Content -LiteralPath $positive.Observation -Raw -Encoding UTF8 | ConvertFrom-Json
    $observation.lock_exists = $true
    Write-CaseObservation -Case $positive -Observation $observation
    [void](Assert-ValidationResult -Case $positive -TransactionRoot $positive.Transaction -ExitCode 7 -Result 'rejected' -Tag '[UPGRADE_APPLY_RUNTIME_FAIL]')

    Restore-PreparedBaseline -Case $positive -Baseline $baseline -Name 'metadata-drift'
    $observation = Get-Content -LiteralPath $positive.Observation -Raw -Encoding UTF8 | ConvertFrom-Json
    $observation.fixture_backend_mode = '700'
    Write-CaseObservation -Case $positive -Observation $observation
    [void](Assert-ValidationResult -Case $positive -TransactionRoot $positive.Transaction -ExitCode 7 -Result 'rejected' -Tag '[UPGRADE_APPLY_METADATA_FAIL]')

    Restore-PreparedBaseline -Case $positive -Baseline $baseline -Name 'duplicate'
    Copy-Item -LiteralPath $positive.Transaction -Destination (Join-Path $positive.Transactions 'duplicate-prepared') -Recurse
    [void](Assert-ValidationResult -Case $positive -TransactionRoot $positive.Transaction -ExitCode 7 -Result 'rejected' -Tag '[UPGRADE_APPLY_TRANSACTION_FAIL]')

    Restore-PreparedBaseline -Case $positive -Baseline $baseline -Name 'overlap'
    $overlapRoot = Join-Path $positive.Frontend 'selected-transaction'
    Copy-Item -LiteralPath $positive.Transaction -Destination $overlapRoot -Recurse
    [void](Assert-ValidationResult -Case $positive -TransactionRoot $overlapRoot -ExitCode 7 -Result 'rejected' -Tag '[UPGRADE_APPLY_BOUNDARY_FAIL]')

    Restore-PreparedBaseline -Case $positive -Baseline $baseline -Name 'reparse'
    $outsideTransaction = Join-Path $OutsideRoot 'reparse-transaction'
    Move-Item -LiteralPath $positive.Transaction -Destination $outsideTransaction
    $JunctionPath = $positive.Transaction
    & cmd.exe /c mklink /J "`"$JunctionPath`"" "`"$outsideTransaction`"" | Out-Null
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $JunctionPath)) 'Unable to create TEMP transaction junction.'
    [void](Assert-ValidationResult -Case $positive -TransactionRoot $JunctionPath -ExitCode 7 -Result 'rejected' -Tag '[UPGRADE_APPLY_BOUNDARY_FAIL]')
    [IO.Directory]::Delete($JunctionPath)
    $JunctionPath = $null

    # 正式內部模式不能因呼叫者傳入 TEMP 路徑而降級成任意路徑寫入能力。
    $boundary = New-PreparedCase -Name 'formal-boundary-lock'
    $boundaryTargets = Get-CaseTargetCanonical $boundary
    $boundaryTransaction = Get-TreeCanonical $boundary.Transaction
    $formalRejected = Invoke-UpgradeProcess -Case $boundary -Mode 'ApplyFormalInternal' -TransactionRoot $boundary.Transaction
    Assert-True ($formalRejected.ExitCode -eq 8 -and $formalRejected.Json.result -eq 'indeterminate') "TEMP paths were accepted by ApplyFormalInternal. stdout=$($formalRejected.Stdout) stderr=$($formalRejected.Stderr)"
    Assert-True ($formalRejected.Stderr -match '\[UPGRADE_APPLY_BOUNDARY_FAIL\]') 'Formal internal mode did not report its hard path boundary.'
    Assert-True ((Get-CaseTargetCanonical $boundary) -ceq $boundaryTargets -and (Get-TreeCanonical $boundary.Transaction) -ceq $boundaryTransaction) 'Rejected formal internal mode changed TEMP evidence.'

    # 同一個隔離 upgrade lock 被其他程序持有時，apply 必須在任何 target write 前停手。
    $lockPath = Join-Path $boundary.Root 'formal-upgrade.lock'
    $lockStream = $null
    try {
        $lockStream = [IO.FileStream]::new($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $lockRejected = Invoke-UpgradeProcess -Case $boundary -Mode 'ApplyFormalFixture' -TransactionRoot $boundary.Transaction
        Assert-True ($lockRejected.ExitCode -eq 8 -and $lockRejected.Stderr -match '\[UPGRADE_APPLY_LOCK_FAIL\]') "Held single upgrade lock did not stop apply. stdout=$($lockRejected.Stdout) stderr=$($lockRejected.Stderr)"
        Assert-True ((Get-CaseTargetCanonical $boundary) -ceq $boundaryTargets -and (Get-TreeCanonical $boundary.Transaction) -ceq $boundaryTransaction) 'Lock rejection changed targets or transaction evidence.'
    }
    finally {
        if ($null -ne $lockStream) { $lockStream.Dispose() }
        if (Test-Path -LiteralPath $lockPath) { Remove-Item -LiteralPath $lockPath -Force }
    }

    # 正常安裝：一般檔案全數核對後，版本標記才依 Backend→Frontend 最後寫入。
    Restore-PreparedBaseline -Case $positive -Baseline $baseline -Name 'fixture-install-success'
    $protectedBefore = Get-ProtectedCanonical $positive
    $installed = Invoke-UpgradeProcess -Case $positive -Mode 'ApplyFormalFixture' -TransactionRoot $positive.Transaction
    Assert-True ($installed.ExitCode -eq 0 -and $installed.Json.result -eq 'installed_pending_acceptance') "Normal fixture install failed. stdout=$($installed.Stdout) stderr=$($installed.Stderr)"
    Assert-CaseInstalledPendingAcceptance -Case $positive -ProtectedBefore $protectedBefore -Label 'normal-install'

    # 三個 runtime checkpoint：前兩個仍可自動還原；marker 前重現 runtime 時不得再寫 marker 或自動 rollback。
    foreach ($runtimeFailure in @('RuntimeAfterUpgradeLock', 'RuntimeBeforeFirstWrite')) {
        Invoke-FailureRollbackCase -Case $positive -Baseline $baseline -Failure $runtimeFailure
    }

    Restore-PreparedBaseline -Case $positive -Baseline $baseline -Name 'runtime-before-markers'
    $runtimeBefore = Get-CaseTargetCanonical $positive
    $runtimeProtected = Get-ProtectedCanonical $positive
    $runtimeInterrupted = Invoke-UpgradeProcess -Case $positive -Mode 'ApplyFormalFixture' -TransactionRoot $positive.Transaction -FormalFailure 'RuntimeBeforeMarkers'
    Assert-True ($runtimeInterrupted.ExitCode -eq 8 -and $runtimeInterrupted.Json.result -eq 'interrupted') "Runtime-before-markers did not preserve an explicit interruption. stdout=$($runtimeInterrupted.Stdout) stderr=$($runtimeInterrupted.Stderr)"
    $runtimeJournal = Read-CaseJournal $positive
    Assert-True ($runtimeJournal.state -eq 'interrupted_runtime' -and [int]$runtimeJournal.fixture_apply.fixture_target_write_count -gt 0 -and [int]$runtimeJournal.fixture_apply.formal_target_write_count -eq 0) 'Runtime-before-markers state/write accounting is wrong.'
    Assert-True (@($runtimeJournal.fixture_apply.marker_order).Count -eq 0 -and (Get-Content -LiteralPath (Join-Path $positive.Backend 'version.txt') -Raw -Encoding ASCII) -eq $SourceMarker -and (Get-Content -LiteralPath (Join-Path $positive.Frontend 'version.txt') -Raw -Encoding ASCII) -eq $SourceMarker) 'Runtime-before-markers changed a version marker.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $positive.Root 'formal-upgrade.lock'))) 'Interrupted runtime retained the single upgrade lock.'
    $runtimeRecovered = Invoke-UpgradeProcess -Case $positive -Mode 'RecoverFormalFixture' -TransactionRoot $positive.Transaction
    Assert-True ($runtimeRecovered.ExitCode -eq 0 -and $runtimeRecovered.Json.result -eq 'rolled_back') "Explicit recovery after runtime quiescence failed. stdout=$($runtimeRecovered.Stdout) stderr=$($runtimeRecovered.Stderr)"
    Assert-CaseRestored -Case $positive -Before $runtimeBefore -ProtectedBefore $runtimeProtected -Label 'runtime-before-markers-recovery'

    # Durable journal proof is a precondition: injected failure before its acknowledgement must produce zero writes.
    Restore-PreparedBaseline -Case $positive -Baseline $baseline -Name 'journal-durability-before-write'
    $durabilityBefore = Get-CaseTargetCanonical $positive
    $durabilityProtected = Get-ProtectedCanonical $positive
    $durability = Invoke-UpgradeProcess -Case $positive -Mode 'ApplyFormalFixture' -TransactionRoot $positive.Transaction -FormalFailure 'JournalDurabilityBeforeFirstWrite'
    Assert-True ($durability.ExitCode -eq 0 -and $durability.Json.result -eq 'rolled_back') "Journal durability injection did not auto-rollback. stdout=$($durability.Stdout) stderr=$($durability.Stderr)"
    Assert-CaseRestored -Case $positive -Before $durabilityBefore -ProtectedBefore $durabilityProtected -Label 'journal-durability-before-write'
    $durabilityJournal = Read-CaseJournal $positive
    Assert-True (-not [bool]$durabilityJournal.fixture_apply.journal_durable_before_first_write -and [int]$durabilityJournal.fixture_apply.fixture_target_write_count -eq 0 -and @($durabilityJournal.fixture_apply.events | Where-Object { $_ -like 'before-write:*' }).Count -eq 0) 'Durability failure allowed or recorded a target write.'

    # 每個關鍵相位的故障都必須自動回到同一份舊版；包含單邊 managed 與單一 marker 已更新。
    foreach ($failure in @(
        'BeforeManagedWrites',
        'AfterFirstManagedWriteBeforeRecord',
        'AfterFrontendManaged',
        'AfterBackendManaged',
        'BeforeBackendMarkerWrite',
        'AfterBackendMarkerWriteBeforeRecord',
        'BeforeFrontendMarkerWrite',
        'AfterFrontendMarkerWriteBeforeRecord',
        'AfterAllMarkers'
    )) {
        Invoke-FailureRollbackCase -Case $positive -Baseline $baseline -Failure $failure
    }

    # 原本不存在與應刪除的舊檔：正常安裝存在狀態正確，故障後也能精確還原。
    $absent = New-PreparedCase -Name 'originally-absent' -Variant 'OriginallyAbsent'
    $absentBaseline = Save-PreparedBaseline -Case $absent -Label 'absent'
    $absentProtected = Get-ProtectedCanonical $absent
    $absentInstall = Invoke-UpgradeProcess -Case $absent -Mode 'ApplyFormalFixture' -TransactionRoot $absent.Transaction
    Assert-True ($absentInstall.ExitCode -eq 0) "OriginallyAbsent normal install failed: $($absentInstall.Stderr)"
    Assert-CaseInstalledPendingAcceptance -Case $absent -ProtectedBefore $absentProtected -Label 'originally-absent-install'
    Assert-True (Test-Path -LiteralPath (Join-Path $absent.Frontend 'run_dev_ui.bat') -PathType Leaf) 'Originally absent managed file was not added.'
    Invoke-FailureRollbackCase -Case $absent -Baseline $absentBaseline -Failure 'AfterAllMarkers'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $absent.Frontend 'run_dev_ui.bat'))) 'Originally absent file existence was not restored.'

    $extra = New-PreparedCase -Name 'extra-delete' -Variant 'ExtraDelete'
    $extraBaseline = Save-PreparedBaseline -Case $extra -Label 'extra'
    $extraPath = Join-Path $extra.Frontend 'src\mixed-extra-delete.fixture'
    $extraProtected = Get-ProtectedCanonical $extra
    $extraInstall = Invoke-UpgradeProcess -Case $extra -Mode 'ApplyFormalFixture' -TransactionRoot $extra.Transaction
    Assert-True ($extraInstall.ExitCode -eq 0) "ExtraDelete normal install failed: $($extraInstall.Stderr)"
    Assert-CaseInstalledPendingAcceptance -Case $extra -ProtectedBefore $extraProtected -Label 'extra-delete-install'
    Assert-True (-not (Test-Path -LiteralPath $extraPath)) 'Ruled old extra file was not deleted.'
    Invoke-FailureRollbackCase -Case $extra -Baseline $extraBaseline -Failure 'AfterAllMarkers'
    Assert-True (Test-Path -LiteralPath $extraPath -PathType Leaf) 'Deleted old extra file was not restored.'

    # 前段完整矩陣可能接近 30 分鐘資格上限；重入組使用新交易，不得放寬 freshness 規則。
    $reentry = New-PreparedCase -Name 'reentry-fresh'
    $reentryBaseline = Save-PreparedBaseline -Case $reentry -Label 'reentry'

    # 突然中止：檔案已寫但該檔 acknowledgement 尚未落盤，重入須依實檔與 sealed evidence 還原。
    Restore-PreparedBaseline -Case $reentry -Baseline $reentryBaseline -Name 'abrupt-reentry'
    $abruptBefore = Get-CaseTargetCanonical $reentry
    $abruptProtected = Get-ProtectedCanonical $reentry
    $abrupt = Invoke-UpgradeProcess -Case $reentry -Mode 'ApplyFormalFixture' -TransactionRoot $reentry.Transaction -FormalFailure 'AbruptAfterFirstManagedWriteBeforeRecord'
    Assert-True ($abrupt.ExitCode -eq 8 -and $abrupt.Json.result -eq 'interrupted') "Abrupt stop was not preserved. stdout=$($abrupt.Stdout) stderr=$($abrupt.Stderr)"
    $abruptJournal = Read-CaseJournal $reentry
    Assert-True ($abruptJournal.fixture_apply.current_operation.phase -eq 'before_write' -and (Get-CaseTargetCanonical $reentry) -cne $abruptBefore) 'Abrupt case did not leave file-ahead-of-journal evidence.'
    $recovered = Invoke-UpgradeProcess -Case $reentry -Mode 'RecoverFormalFixture' -TransactionRoot $reentry.Transaction
    Assert-True ($recovered.ExitCode -eq 0 -and $recovered.Json.result -eq 'rolled_back') "Abrupt recovery failed. stdout=$($recovered.Stdout) stderr=$($recovered.Stderr)"
    Assert-CaseRestored -Case $reentry -Before $abruptBefore -ProtectedBefore $abruptProtected -Label 'abrupt-reentry'
    $already = Invoke-UpgradeProcess -Case $reentry -Mode 'RecoverFormalFixture' -TransactionRoot $reentry.Transaction
    Assert-True ($already.ExitCode -eq 0 -and $already.Json.result -eq 'rolled_back') 'Already-restored reentry was not idempotently recognized.'

    # 未知第三方內容：不得用 package 或 preimage 覆蓋，必須標記 indeterminate 並保留證據。
    Restore-PreparedBaseline -Case $reentry -Baseline $reentryBaseline -Name 'unknown-content'
    $unknown = Invoke-UpgradeProcess -Case $reentry -Mode 'ApplyFormalFixture' -TransactionRoot $reentry.Transaction -FormalFailure 'AbruptAfterFirstManagedWriteBeforeRecord'
    Assert-True ($unknown.ExitCode -eq 8) 'Unknown-content setup did not interrupt.'
    $unknownJournal = Read-CaseJournal $reentry
    $unknownKey = [string]$unknownJournal.fixture_apply.current_operation.key
    $unknownRecord = @($unknownJournal.fixture_apply.files | Where-Object key -eq $unknownKey)[0]
    'third-party-unknown-content' | Set-Content -LiteralPath $unknownRecord.target_path -Encoding UTF8
    $unknownHash = Get-Sha $unknownRecord.target_path
    $unknownRecovery = Invoke-UpgradeProcess -Case $reentry -Mode 'RecoverFormalFixture' -TransactionRoot $reentry.Transaction
    Assert-True ($unknownRecovery.ExitCode -eq 8 -and $unknownRecovery.Json.result -eq 'indeterminate') 'Unknown content did not stop as indeterminate.'
    Assert-True ((Get-Sha $unknownRecord.target_path) -eq $unknownHash) 'Unknown third-party content was overwritten.'

    # 使用者資料外部變化：停手且不拿舊備份覆蓋。
    Restore-PreparedBaseline -Case $reentry -Baseline $reentryBaseline -Name 'protected-change-reentry'
    [void](Invoke-UpgradeProcess -Case $reentry -Mode 'ApplyFormalFixture' -TransactionRoot $reentry.Transaction -FormalFailure 'AbruptAfterFirstManagedWriteBeforeRecord')
    'external-user-data-change' | Add-Content -LiteralPath $reentry.Projects -Encoding UTF8
    $changedProtectedHash = Get-Sha $reentry.Projects
    $protectedRecovery = Invoke-UpgradeProcess -Case $reentry -Mode 'RecoverFormalFixture' -TransactionRoot $reentry.Transaction
    Assert-True ($protectedRecovery.ExitCode -eq 8 -and $protectedRecovery.Json.result -eq 'indeterminate') 'Protected-data change did not stop as indeterminate.'
    Assert-True ((Get-Sha $reentry.Projects) -eq $changedProtectedHash) 'Changed protected data was overwritten.'

    # 證據損壞：保留損壞證據與半套目標，不自動重試或猜測。
    Restore-PreparedBaseline -Case $reentry -Baseline $reentryBaseline -Name 'evidence-damage-reentry'
    [void](Invoke-UpgradeProcess -Case $reentry -Mode 'ApplyFormalFixture' -TransactionRoot $reentry.Transaction -FormalFailure 'AbruptAfterFirstManagedWriteBeforeRecord')
    $evidenceJournal = Read-CaseJournal $reentry
    $evidenceKey = [string]$evidenceJournal.fixture_apply.current_operation.key
    $evidenceRecord = @($evidenceJournal.fixture_apply.files | Where-Object key -eq $evidenceKey)[0]
    'damaged-package-evidence' | Add-Content -LiteralPath $evidenceRecord.package_path -Encoding UTF8
    $damagedEvidenceHash = Get-Sha $evidenceRecord.package_path
    $evidenceRecovery = Invoke-UpgradeProcess -Case $reentry -Mode 'RecoverFormalFixture' -TransactionRoot $reentry.Transaction
    Assert-True ($evidenceRecovery.ExitCode -eq 8 -and $evidenceRecovery.Json.result -eq 'indeterminate') 'Damaged evidence did not stop as indeterminate.'
    Assert-True ((Get-Sha $evidenceRecord.package_path) -eq $damagedEvidenceHash) 'Damaged evidence was rewritten.'

    # Journal 路徑被改壞時，即使仍在 fake root 內也不得轉寫到保護資料。
    Restore-PreparedBaseline -Case $reentry -Baseline $reentryBaseline -Name 'journal-redirect-reentry'
    [void](Invoke-UpgradeProcess -Case $reentry -Mode 'ApplyFormalFixture' -TransactionRoot $reentry.Transaction -FormalFailure 'AbruptAfterFirstManagedWriteBeforeRecord')
    $redirectJournal = Read-CaseJournal $reentry
    $redirectKey = [string]$redirectJournal.fixture_apply.current_operation.key
    $redirectRecord = @($redirectJournal.fixture_apply.files | Where-Object key -eq $redirectKey)[0]
    $redirectRecord.target_path = $reentry.Projects
    $redirectRecord.temp_path = "$($reentry.Projects).$($redirectJournal.transaction_id).tmp"
    $redirectJournal | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $reentry.Journal -Encoding UTF8
    $redirectProtected = Get-ProtectedCanonical $reentry
    $redirectRecovery = Invoke-UpgradeProcess -Case $reentry -Mode 'RecoverFormalFixture' -TransactionRoot $reentry.Transaction
    Assert-True ($redirectRecovery.ExitCode -eq 8 -and $redirectRecovery.Json.result -eq 'indeterminate') 'Journal redirect did not stop as indeterminate.'
    Assert-True ((Get-ProtectedCanonical $reentry) -ceq $redirectProtected) 'Corrupt journal redirected a write into protected data.'

    # 還原本身故障：標記 rollback_failed，後續重入不得自動再試。
    Restore-PreparedBaseline -Case $reentry -Baseline $reentryBaseline -Name 'rollback-failure'
    [void](Invoke-UpgradeProcess -Case $reentry -Mode 'ApplyFormalFixture' -TransactionRoot $reentry.Transaction -FormalFailure 'AbruptAfterFirstManagedWriteBeforeRecord')
    $rollbackFailed = Invoke-UpgradeProcess -Case $reentry -Mode 'RecoverFormalFixture' -TransactionRoot $reentry.Transaction -FormalFailure 'RollbackBeforeFirstRestore'
    Assert-True ($rollbackFailed.ExitCode -eq 8 -and $rollbackFailed.Json.result -eq 'rollback_failed') 'Injected rollback failure was not retained.'
    $failedTargets = Get-CaseTargetCanonical $reentry
    $noRetry = Invoke-UpgradeProcess -Case $reentry -Mode 'RecoverFormalFixture' -TransactionRoot $reentry.Transaction
    Assert-True ($noRetry.ExitCode -eq 8 -and $noRetry.Json.result -eq 'rollback_failed') 'Rollback-failed transaction was retried automatically.'
    Assert-True ((Get-CaseTargetCanonical $reentry) -ceq $failedTargets) 'Rollback-failed no-retry reentry changed targets.'

    $upgradeBatText = Get-Content -LiteralPath $UpgradeBat -Raw -Encoding UTF8
    Assert-True ($upgradeBatText -notmatch 'ValidateFormalApply|PrepareFormal|ApplyFormalFixture|RecoverFormalFixture|ApplyFormalInternal|RecoverFormalInternal') 'upgrade.bat publicly exposes an internal formal mode.'
    $upgradeText = Get-Content -LiteralPath $UpgradeScript -Raw -Encoding UTF8
    $formalApplyText = Get-Content -LiteralPath $FormalApplyScript -Raw -Encoding UTF8
    Assert-True ($upgradeText -match "'ApplyFormalInternal'" -and $upgradeText -match "'RecoverFormalInternal'") 'Internal formal apply/recovery dispatch is missing.'
    foreach ($contractPattern in @(
        '\[IO\.FileShare\]::None',
        '\.Flush\(\$true\)',
        "'after-upgrade-lock'",
        "'before-first-target-write'",
        "'before-version-markers'",
        'SetSecurityDescriptorSddlForm',
        '--exec chown',
        '--exec chmod',
        'content\+existence\+mtime\+attributes\+sddl',
        'content\+existence\+mtime\+uid\+gid\+mode'
    )) {
        Assert-True ($formalApplyText -match $contractPattern) "Formal write metadata/lock/checkpoint contract is missing: $contractPattern"
    }
    Assert-True ((Get-FormalBoundaryCanonical) -ceq $formalBefore) 'Formal Windows/WSL targets or formal transaction root changed.'

    Remove-TestTree $SuiteRoot
    Remove-TestTree $OutsideRoot
    Assert-True (-not (Test-Path -LiteralPath $SuiteRoot)) 'Suite TEMP residue remains.'
    Assert-True (-not (Test-Path -LiteralPath $OutsideRoot)) 'Outside TEMP residue remains.'
    Write-Output 'upgrade formal apply validation/install/recovery smoke: PASS'
    exit 0
}
catch {
    [Console]::Error.WriteLine("upgrade formal apply validation/install/recovery smoke: FAIL: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))")
    try {
        if ($JunctionPath -and (Test-Path -LiteralPath $JunctionPath)) { [IO.Directory]::Delete($JunctionPath) }
        if (Test-Path -LiteralPath $SuiteRoot) { Remove-TestTree $SuiteRoot }
        if (Test-Path -LiteralPath $OutsideRoot) { Remove-TestTree $OutsideRoot }
    }
    catch { [Console]::Error.WriteLine("cleanup failure: $($_.Exception.Message)") }
    exit 1
}
