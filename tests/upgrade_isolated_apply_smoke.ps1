[CmdletBinding()]
param()

<#
.SYNOPSIS
Proves the internal ApplyIsolated transaction and rollback contract under TEMP.

.DESCRIPTION
Purpose: exercise success, preflight rejection, failure injection, unfinished-journal recovery, and protected-data invariants.
Inputs: repository HEAD plus generated fake Frontend/Backend targets under one TEMP isolation root per case.
Outputs: one PASS/FAIL result; transaction evidence exists only during the test.
SSOT Output: process exit code; zero means every isolated transaction assertion passed.
Exit codes: 0 pass, 1 assertion or script failure.
Side effects: creates and removes verified child directories under TEMP; never invokes the public runner or formal runtime.
#>

# 這支腳本在做什麼：用 TEMP 假目標證明逐檔 apply、hash、journal、rollback 與失敗恢復。
# 這支腳本不做什麼：不碰 upgrade.bat、正式 runtime、Git 寫入或任何真實程序。
# 常改區塊：案例矩陣、故障注入與不變項斷言。
# 不要亂動的區塊：TEMP 邊界、正式目標禁止、projects/config/hash 前後比對。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$UpgradeScript = Join-Path $RepoRoot 'scripts\upgrade.ps1'
$TempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
$SuiteRoot = Join-Path $TempBase ('LaplaceSentryApplyTest_' + [Guid]::NewGuid().ToString('N'))
$OldVersion = (& git -C $RepoRoot merge-base HEAD origin/main).Trim()
$HeadVersion = (& git -C $RepoRoot rev-parse --short HEAD).Trim()

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "[ASSERT_FAIL] $Message" }
}

function Get-Sha {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function New-IsolatedCase {
    param([string]$Name)
    $root = Join-Path $SuiteRoot $Name
    $frontend = Join-Path $root 'fake-frontend'
    $backend = Join-Path $root 'fake-backend'
    $stage = Join-Path $root 'transaction'
    New-Item -ItemType Directory -Path (Join-Path $frontend 'src\tray') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $backend 'src\core') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $backend 'data') -Force | Out-Null
    'eye_size=77' | Set-Content -LiteralPath (Join-Path $frontend 'sentry_config.ini') -Encoding UTF8
    '[{"uuid":"must-survive","name":"isolated"}]' | Set-Content -LiteralPath (Join-Path $backend 'data\projects.json') -Encoding UTF8
    $OldVersion | Set-Content -LiteralPath (Join-Path $frontend 'version.txt') -Encoding ASCII -NoNewline
    $OldVersion | Set-Content -LiteralPath (Join-Path $backend 'version.txt') -Encoding ASCII -NoNewline
    'old frontend managed content' | Set-Content -LiteralPath (Join-Path $frontend 'src\tray\tray_app.py') -Encoding UTF8
    'old backend managed content' | Set-Content -LiteralPath (Join-Path $backend 'src\core\daemon.py') -Encoding UTF8
    'overlay must survive' | Set-Content -LiteralPath (Join-Path $frontend 'local-extra.txt') -Encoding UTF8
    return [pscustomobject]@{
        Root = $root
        Frontend = $frontend
        Backend = $backend
        Stage = $stage
        Config = Join-Path $frontend 'sentry_config.ini'
        Projects = Join-Path $backend 'data\projects.json'
        FrontendOld = Join-Path $frontend 'src\tray\tray_app.py'
        BackendOld = Join-Path $backend 'src\core\daemon.py'
        NewFile = Join-Path $frontend 'src\backend\adapter.py'
        Extra = Join-Path $frontend 'local-extra.txt'
    }
}

function Get-CaseSnapshot {
    param($Case)
    return [pscustomobject]@{
        Config = Get-Sha $Case.Config
        Projects = Get-Sha $Case.Projects
        FrontendOld = Get-Sha $Case.FrontendOld
        BackendOld = Get-Sha $Case.BackendOld
        Extra = Get-Sha $Case.Extra
        FrontendVersion = Get-Sha (Join-Path $Case.Frontend 'version.txt')
        BackendVersion = Get-Sha (Join-Path $Case.Backend 'version.txt')
    }
}

function Invoke-UpgradeCase {
    param(
        $Case,
        [string]$Action = 'Apply',
        [string]$Injection = 'None'
    )
    $priorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $UpgradeScript -Mode ApplyIsolated -IsolationRoot $Case.Root -StagingRoot $Case.Stage -FrontendTarget $Case.Frontend -BackendTarget $Case.Backend -IsolatedAction $Action -FailureInjection $Injection 2>&1)
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $priorPreference
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Assert-Restored {
    param($Case, $Before, [string]$Label)
    Assert-True ((Get-Sha $Case.Config) -eq $Before.Config) "$Label changed protected Frontend config."
    Assert-True ((Get-Sha $Case.Projects) -eq $Before.Projects) "$Label changed protected Backend projects.json."
    Assert-True ((Get-Sha $Case.FrontendOld) -eq $Before.FrontendOld) "$Label did not restore existing Frontend managed file."
    Assert-True ((Get-Sha $Case.BackendOld) -eq $Before.BackendOld) "$Label did not restore existing Backend managed file."
    Assert-True ((Get-Sha $Case.Extra) -eq $Before.Extra) "$Label changed overlay extra file."
    Assert-True (-not (Test-Path -LiteralPath $Case.NewFile)) "$Label did not remove a newly introduced managed file."
    Assert-True ((Get-Sha (Join-Path $Case.Frontend 'version.txt')) -eq $Before.FrontendVersion) "$Label did not restore the exact Frontend version bytes."
    Assert-True ((Get-Sha (Join-Path $Case.Backend 'version.txt')) -eq $Before.BackendVersion) "$Label did not restore the exact Backend version bytes."
    Assert-True ((Get-Content -LiteralPath (Join-Path $Case.Frontend 'version.txt') -Raw).Trim() -eq $OldVersion) "$Label did not restore Frontend version."
    Assert-True ((Get-Content -LiteralPath (Join-Path $Case.Backend 'version.txt') -Raw).Trim() -eq $OldVersion) "$Label did not restore Backend version."
}

function Assert-OverlapRejectedWithoutWrites {
    param(
        [string]$Label,
        [string]$IsolationRoot,
        [string]$Stage,
        [string]$Frontend,
        [string]$Backend
    )
    $priorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $UpgradeScript -Mode ApplyIsolated -IsolationRoot $IsolationRoot -StagingRoot $Stage -FrontendTarget $Frontend -BackendTarget $Backend -FailureInjection DirtySource 2>&1)
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $priorPreference
    $outputText = $output -join "`n"
    Assert-True ($exitCode -eq 4) "$Label did not return isolated exit 4."
    Assert-True ($outputText -match '\[UPGRADE_ISOLATED_PREFLIGHT_FAIL\]') "$Label did not report an isolated boundary rejection."
    Assert-True (-not (Test-Path -LiteralPath $IsolationRoot)) "$Label created isolation, journal, package, preimage, or target data before rejection."
}

try {
    $resolvedSuite = [System.IO.Path]::GetFullPath($SuiteRoot)
    Assert-True ($resolvedSuite.StartsWith($TempBase + '\', [System.StringComparison]::OrdinalIgnoreCase)) 'Suite root escaped TEMP.'
    New-Item -ItemType Directory -Path $SuiteRoot -Force | Out-Null

    $success = New-IsolatedCase 'success'
    $successBefore = Get-CaseSnapshot $success
    $successResult = Invoke-UpgradeCase $success
    Assert-True ($successResult.ExitCode -eq 0) "Success case failed: $($successResult.Output -join ' ')"
    $successJournal = Get-Content -LiteralPath (Join-Path $success.Stage 'transaction-journal.json') -Raw | ConvertFrom-Json
    Assert-True ($successJournal.state -eq 'committed') 'Success journal was not committed.'
    Assert-True ($successJournal.head_commit -eq (& git -C $RepoRoot rev-parse HEAD).Trim()) 'Journal HEAD mismatch.'
    Assert-True (-not [string]::IsNullOrWhiteSpace($successJournal.manifest_sha256)) 'Journal manifest hash missing.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $success.Frontend 'version.txt') -Raw).Trim() -eq $HeadVersion) 'Success Frontend version mismatch.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $success.Backend 'version.txt') -Raw).Trim() -eq $HeadVersion) 'Success Backend version mismatch.'
    Assert-True ((Get-Sha $success.Config) -eq $successBefore.Config) 'Success changed protected Frontend config.'
    Assert-True ((Get-Sha $success.Projects) -eq $successBefore.Projects) 'Success changed protected Backend projects.json.'
    Assert-True ((Get-Sha $success.Extra) -eq $successBefore.Extra) 'Success deleted overlay extra file.'
    Assert-True ((Get-Sha $success.NewFile) -eq (Get-Sha (Join-Path $RepoRoot 'Frontend\src\backend\adapter.py'))) 'Success target hash did not match the managed source.'

    $dirty = New-IsolatedCase 'dirty-source-reject'
    $dirtyBefore = Get-CaseSnapshot $dirty
    $dirtyResult = Invoke-UpgradeCase -Case $dirty -Injection 'DirtySource'
    Assert-True ($dirtyResult.ExitCode -eq 4) 'Dirty source injection was not rejected.'
    Assert-True (-not (Test-Path -LiteralPath $dirty.Stage)) 'Dirty source rejection wrote a staging transaction.'
    Assert-Restored -Case $dirty -Before $dirtyBefore -Label 'Dirty source rejection'

    foreach ($injection in @('FrontendApply', 'BackendApply', 'Version', 'Smoke')) {
        $case = New-IsolatedCase ("rollback-" + $injection.ToLowerInvariant())
        $before = Get-CaseSnapshot $case
        $result = Invoke-UpgradeCase -Case $case -Injection $injection
        Assert-True ($result.ExitCode -eq 4) "$injection did not return the isolated failure exit code."
        $journal = Get-Content -LiteralPath (Join-Path $case.Stage 'transaction-journal.json') -Raw | ConvertFrom-Json
        Assert-True ($journal.state -eq 'rolled_back') "$injection did not finish rollback."
        Assert-True ($journal.last_completed_step -eq 'rollback-complete') "$injection journal lacks rollback completion."
        Assert-Restored -Case $case -Before $before -Label $injection
    }

    $unfinished = New-IsolatedCase 'rollback-failure'
    $unfinishedBefore = Get-CaseSnapshot $unfinished
    $failedRollback = Invoke-UpgradeCase -Case $unfinished -Injection 'Rollback'
    Assert-True ($failedRollback.ExitCode -eq 4) 'Rollback failure injection did not fail.'
    $failedJournalPath = Join-Path $unfinished.Stage 'transaction-journal.json'
    $failedJournal = Get-Content -LiteralPath $failedJournalPath -Raw | ConvertFrom-Json
    Assert-True ($failedJournal.state -eq 'rollback_failed') 'Rollback failure evidence state missing.'
    Assert-True (-not [string]::IsNullOrWhiteSpace($failedJournal.failed_file)) 'Rollback failure evidence lacks failed file.'
    Assert-True (-not [string]::IsNullOrWhiteSpace($failedJournal.last_completed_step)) 'Rollback failure evidence lacks last completed step.'
    $rerun = Invoke-UpgradeCase -Case $unfinished
    Assert-True ($rerun.ExitCode -eq 4) 'Apply rerun incorrectly continued an unfinished transaction.'
    $recovery = Invoke-UpgradeCase -Case $unfinished -Action 'Rollback'
    Assert-True ($recovery.ExitCode -eq 0) "Explicit rollback recovery failed: $($recovery.Output -join ' ')"
    Assert-Restored -Case $unfinished -Before $unfinishedBefore -Label 'Explicit rollback recovery'

    $boundary = New-IsolatedCase 'boundary-reject'
    $boundaryBefore = Get-CaseSnapshot $boundary
    $outsideTarget = Join-Path $TempBase ('LaplaceSentryOutside_' + [Guid]::NewGuid().ToString('N'))
    $formalFrontend = Join-Path $env:LOCALAPPDATA 'LaplaceSentry'
    foreach ($rejectedTarget in @($outsideTarget, $RepoRoot, $formalFrontend)) {
        $priorPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $boundaryOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $UpgradeScript -Mode ApplyIsolated -IsolationRoot $boundary.Root -StagingRoot $boundary.Stage -FrontendTarget $rejectedTarget -BackendTarget $boundary.Backend 2>&1)
        $boundaryExit = $LASTEXITCODE
        $ErrorActionPreference = $priorPreference
        Assert-True ($boundaryExit -eq 4) "Forbidden target was not rejected: $rejectedTarget"
    }
    Assert-True (-not (Test-Path -LiteralPath $outsideTarget)) 'Rejected outside-isolation target was written.'
    Assert-True (-not (Test-Path -LiteralPath $boundary.Stage)) 'Boundary rejection wrote staging data.'
    Assert-Restored -Case $boundary -Before $boundaryBefore -Label 'Boundary rejection'

    $overlapRoot = Join-Path $SuiteRoot 'overlap-rejections'
    $overlapCases = @(
        [pscustomobject]@{ Label = 'staging inside Frontend'; Root = Join-Path $overlapRoot 'stage-in-front'; Stage = Join-Path $overlapRoot 'stage-in-front\frontend\stage'; Frontend = Join-Path $overlapRoot 'stage-in-front\frontend'; Backend = Join-Path $overlapRoot 'stage-in-front\backend' },
        [pscustomobject]@{ Label = 'Frontend inside staging'; Root = Join-Path $overlapRoot 'front-in-stage'; Stage = Join-Path $overlapRoot 'front-in-stage\stage'; Frontend = Join-Path $overlapRoot 'front-in-stage\stage\frontend'; Backend = Join-Path $overlapRoot 'front-in-stage\backend' },
        [pscustomobject]@{ Label = 'staging inside Backend'; Root = Join-Path $overlapRoot 'stage-in-back'; Stage = Join-Path $overlapRoot 'stage-in-back\backend\stage'; Frontend = Join-Path $overlapRoot 'stage-in-back\frontend'; Backend = Join-Path $overlapRoot 'stage-in-back\backend' },
        [pscustomobject]@{ Label = 'Backend inside staging'; Root = Join-Path $overlapRoot 'back-in-stage'; Stage = Join-Path $overlapRoot 'back-in-stage\stage'; Frontend = Join-Path $overlapRoot 'back-in-stage\frontend'; Backend = Join-Path $overlapRoot 'back-in-stage\stage\backend' },
        [pscustomobject]@{ Label = 'Frontend inside Backend'; Root = Join-Path $overlapRoot 'front-in-back'; Stage = Join-Path $overlapRoot 'front-in-back\stage'; Frontend = Join-Path $overlapRoot 'front-in-back\backend\frontend'; Backend = Join-Path $overlapRoot 'front-in-back\backend' },
        [pscustomobject]@{ Label = 'Backend inside Frontend'; Root = Join-Path $overlapRoot 'back-in-front'; Stage = Join-Path $overlapRoot 'back-in-front\stage'; Frontend = Join-Path $overlapRoot 'back-in-front\frontend'; Backend = Join-Path $overlapRoot 'back-in-front\frontend\backend' },
        [pscustomobject]@{ Label = 'equal staging and Frontend'; Root = Join-Path $overlapRoot 'equal'; Stage = Join-Path $overlapRoot 'equal\shared'; Frontend = Join-Path $overlapRoot 'equal\shared'; Backend = Join-Path $overlapRoot 'equal\backend' }
    )
    foreach ($overlapCase in $overlapCases) {
        Assert-OverlapRejectedWithoutWrites -Label $overlapCase.Label -IsolationRoot $overlapCase.Root -Stage $overlapCase.Stage -Frontend $overlapCase.Frontend -Backend $overlapCase.Backend
    }

    Write-Output '[PASS] isolated apply transaction proved success, seven overlap rejections, four rollback cuts, dirty/boundary rejection, unfinished-journal gating, and explicit recovery.'
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
finally {
    if (Test-Path -LiteralPath $SuiteRoot) {
        $resolvedDelete = [System.IO.Path]::GetFullPath($SuiteRoot)
        if ($resolvedDelete.StartsWith($TempBase + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedDelete -Recurse -Force
        }
    }
}
