[CmdletBinding()]
param()

<#
.SYNOPSIS
Runs the S-02-03b upgrade first-stage rehearsal entirely under the temp directory.

.DESCRIPTION
Purpose: prove allowlist staging, protected-data backup, and target immutability.
Inputs: repository files and a generated fake runtime under TEMP.
Outputs: PASS/FAIL plus the upgrade manifest path during execution.
SSOT Output: process exit code; zero means every assertion passed.
Exit codes: 0 pass, 1 assertion or script failure.
Side effects: creates and removes one verified child directory under TEMP.
#>

# 這支腳本在做什麼：建立假 Frontend/Backend runtime，驗證升級骨架不碰正式副本。
# 這支腳本不做什麼：不讀寫正式 runtime、不啟停任何程序。
# 常改區塊：隔離案例與斷言。
# 不要亂動的區塊：temp 邊界驗證、projects.json 前後 hash 比對。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$UpgradeEntry = Join-Path $RepoRoot 'upgrade.bat'
$TempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
$CaseRoot = Join-Path $TempBase ("LaplaceSentryUpgradeTest_" + [Guid]::NewGuid().ToString('N'))

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "[ASSERT_FAIL] $Message" }
}

try {
    $resolvedCase = [System.IO.Path]::GetFullPath($CaseRoot)
    Assert-True ($resolvedCase.StartsWith($TempBase + '\', [System.StringComparison]::OrdinalIgnoreCase)) 'Test root escaped TEMP.'

    $fakeFrontend = Join-Path $CaseRoot 'fake-runtime\Frontend'
    $fakeBackend = Join-Path $CaseRoot 'fake-runtime\Backend'
    $stageRoot = Join-Path $CaseRoot 'stage'
    New-Item -ItemType Directory -Path $fakeFrontend -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fakeBackend 'data') -Force | Out-Null

    'eye_size=77' | Set-Content -LiteralPath (Join-Path $fakeFrontend 'sentry_config.ini') -Encoding UTF8
    'old-frontend' | Set-Content -LiteralPath (Join-Path $fakeFrontend 'version.txt') -Encoding UTF8
    '[{"uuid":"must-survive","name":"formal"}]' | Set-Content -LiteralPath (Join-Path $fakeBackend 'data\projects.json') -Encoding UTF8
    'old-backend' | Set-Content -LiteralPath (Join-Path $fakeBackend 'version.txt') -Encoding UTF8

    $projectsPath = Join-Path $fakeBackend 'data\projects.json'
    $projectsHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $projectsPath).Hash

    $repoStageRoot = Join-Path $RepoRoot ('.upgrade-reject-' + [Guid]::NewGuid().ToString('N'))
    Assert-True (-not (Test-Path -LiteralPath $repoStageRoot)) 'Repo-contained rejection path unexpectedly exists.'
    $ErrorActionPreference = 'Continue'
    $repoRejectOutput = @(& cmd.exe /d /c $UpgradeEntry --stage -StagingRoot $repoStageRoot -FrontendTarget $fakeFrontend -BackendTarget $fakeBackend 2>&1)
    $repoRejectExitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Assert-True ($repoRejectExitCode -eq 3) 'Repo-contained StagingRoot failure was not returned as exit 3 by upgrade.bat.'
    Assert-True (-not (Test-Path -LiteralPath $repoStageRoot)) 'Rejected repo-contained StagingRoot was created.'

    $ErrorActionPreference = 'Continue'
    $unknownOutput = @(& cmd.exe /d /c $UpgradeEntry --dry-run -DefinitelyUnknown 2>&1)
    $unknownExitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Assert-True ($unknownExitCode -ne 0) 'Forwarded unknown parameter was incorrectly returned as success by upgrade.bat.'

    $stageOutput = @(& cmd.exe /d /c $UpgradeEntry --stage -StagingRoot $stageRoot -FrontendTarget $fakeFrontend -BackendTarget $fakeBackend -BuildVersion 'isolated-test')
    Assert-True ($LASTEXITCODE -eq 0) 'Upgrade stage returned non-zero.'
    Assert-True ($stageOutput.Count -gt 0) 'Upgrade stage did not emit its manifest.'

    Assert-True (Test-Path -LiteralPath (Join-Path $stageRoot 'package\Frontend\src\tray\tray_app.py')) 'Frontend allowlist file missing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $stageRoot 'package\Backend\src\core\daemon.py')) 'Backend allowlist file missing.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stageRoot 'package\Backend\data\projects.json'))) 'Protected projects.json entered package.'
    Assert-True (Test-Path -LiteralPath (Join-Path $stageRoot 'backup\Backend\data\projects.json')) 'Protected projects.json backup missing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $stageRoot 'backup\Frontend\sentry_config.ini')) 'Frontend settings backup missing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $stageRoot 'rollback-plan.json')) 'Rollback plan missing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $stageRoot 'upgrade-plan.json')) 'Upgrade manifest missing.'

    $projectsHashAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $projectsPath).Hash
    Assert-True ($projectsHashBefore -eq $projectsHashAfter) 'Fake formal projects.json was modified.'

    $manifest = Get-Content -LiteralPath (Join-Path $stageRoot 'upgrade-plan.json') -Raw | ConvertFrom-Json
    Assert-True ($manifest.safety -eq 'formal-targets-read-only') 'Manifest safety contract mismatch.'
    Assert-True ($manifest.build_version -eq 'isolated-test') 'Version source override mismatch.'

    Write-Output '[PASS] isolated upgrade rehearsal preserved projects.json and created package/backup/rollback artifacts.'
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
finally {
    if (Test-Path -LiteralPath $CaseRoot) {
        $resolvedDelete = [System.IO.Path]::GetFullPath($CaseRoot)
        if ($resolvedDelete.StartsWith($TempBase + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedDelete -Recurse -Force
        }
    }
}
