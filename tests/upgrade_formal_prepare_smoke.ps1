[CmdletBinding()]
param(
    [ValidateSet('all', 'basis-only', 'metadata', 'formal-boundary', 'success', 'runtime-rejection', 'acl-rejection', 'source-rejection', 'transaction-boundary', 'failure-injection', 'reentry-cleanup')]
    [string[]]$Group = @('all'),

    [ValidateSet('all', 'success-and-rerun', 'active-lock', 'owned-ui', 'owned-daemon', 'owned-worker', 'ambiguous-runtime', 'acl-reject', 'owner-reject', 'space-reject', 'adapter-drift', 'tray-drift', 'marker-drift', 'transaction-overlap', 'transaction-unc', 'transaction-reparse', 'inject-preimage', 'inject-package', 'inject-prepare', 'inject-journal', 'inject-secondsnapshot', 'inject-evidencetamper', 'incomplete-rerun', 'evidence-tamper-rerun', 'multiple-transactions')]
    [string[]]$Case = @('all')
)

<#
.SYNOPSIS
Proves PrepareFormal under isolated TEMP fixtures and the read-only production WSL metadata seam.

.DESCRIPTION
Purpose: exercise prepare success, rejection, interruption, reentry, integrity sealing, the zero-formal-write boundary, and production WSL stat argument handling.
Inputs: fixed Git objects, generated mixed Frontend/Backend targets and observation JSON below system TEMP, plus formal backend main.py as a read-only metadata witness.
Outputs: one PASS/FAIL result; all fixture evidence is removed before exit.
SSOT Output: process exit code; zero means every prepare-only assertion passed.
Exit codes: 0 pass, 1 assertion, boundary, script, or cleanup failure.
SKIP conditions: none.
FAIL conditions: any wrong exit/result/state/count/hash/reentry/boundary result, TEMP residue, or production metadata command/parser result.
Order-sensitive checks: formal-boundary and fixture target snapshots are captured before prepare and compared after every case.
Side effects: creates and removes only verified strict children of system TEMP and issues read-only WSL stat calls; never invokes live PrepareFormal, upgrade.bat, Git writes, processes, registry, or runtime changes.
#>

# 這支腳本在做什麼：用 TEMP 假目標證明完整 prepare 契約，並唯讀走過 production WSL metadata 接縫。
# 這支腳本不做什麼：不執行真實 prepare、不建立正式 transaction root，也不測 apply／repair／rollback。
# 常改區塊：production metadata 接縫、拒絕案例、故障注入、manifest 與重入斷言。
# 不要亂動的區塊：正式邊界前後 fingerprint、嚴格 TEMP 清理與 0 formal target writes。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$UpgradeScript = Join-Path $RepoRoot 'scripts\upgrade.ps1'
$UpgradeBat = Join-Path $RepoRoot 'upgrade.bat'
$TempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
$SuiteRoot = Join-Path $TempBase ('LaplaceSentryFormalPrepareSmoke-' + [Guid]::NewGuid().ToString('N'))
$OutsideRoot = Join-Path $TempBase ('LaplaceSentryFormalPrepareOutside-' + [Guid]::NewGuid().ToString('N'))
$TemplateRoot = Join-Path $SuiteRoot '_template'
$FormalFrontend = Join-Path $env:LOCALAPPDATA 'LaplaceSentry'
$FormalBackend = '\\wsl.localhost\Ubuntu\home\serpal\.laplace_sentry_backend'
$FormalBackendLinux = '/home/serpal/.laplace_sentry_backend'
$FormalTransactions = Join-Path $env:LOCALAPPDATA 'LaplaceSentryUpgrade'

# 測試橋接：prepare helper 只依賴 Git 輸出契約；smoke 不載入會進入 dispatch 的完整 upgrade.ps1。
function Get-GitOutput {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $gitExitCode = $null
    $priorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -C $RepoRoot @Arguments 2>&1)
        $gitExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $priorPreference
    }
    if ($gitExitCode -ne 0) {
        $detail = @($output | ForEach-Object { [string]$_ }) -join ' '
        throw ('[UPGRADE_GIT_FAIL] git {0} failed exit={1} detail={2}' -f ($Arguments -join ' '), $gitExitCode, $detail)
    }
    return @($output)
}

# 直接載入正式目標與純 basis 判定，避免 smoke test 自帶第二份 formal target。
. (Join-Path $RepoRoot 'scripts\upgrade_formal_prepare.ps1')

$TargetCommit = $FormalUpgradeTargetCommit
$TargetShort = $TargetCommit.Substring(0, 7)
$AdapterCommit = '4f228ae5f31754aa43a918274e3b542b6f0a2144'
$SourceMarker = '1e7bc2b'
$FixedTime = [DateTime]::Parse('2024-01-02T03:04:05.0000000Z', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
$FrontendAllowlist = @('assets', 'src', 'requirements.txt', 'run_ui.bat', 'run_ui.vbs', 'run_dev_ui.bat')
$BackendAllowlist = @('main.py', 'requirements.txt', 'src')
$JunctionPath = $null
$SelectedGroups = @($Group)
$SelectedCases = @($Case)
$RunAllCases = $SelectedCases -contains 'all'
$RunAllGroups = $SelectedGroups -contains 'all'
$script:FormalBefore = $null

function Test-SmokeGroup {
    param([Parameter(Mandatory = $true)][string]$Name)
    return [bool]($RunAllGroups -or ($SelectedGroups -contains $Name))
}

function Invoke-SmokeGroup {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    if (-not (Test-SmokeGroup $Name)) {
        Write-Output "prepare smoke group: SKIP name=$Name"
        return
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Write-Output "prepare smoke group: START name=$Name"
    try {
        & $Action
        $watch.Stop()
        Write-Output "prepare smoke group: PASS name=$Name duration_ms=$($watch.ElapsedMilliseconds)"
    }
    catch {
        $watch.Stop()
        Write-Output ("prepare smoke group: FAIL name={0} duration_ms={1} error={2}" -f $Name, $watch.ElapsedMilliseconds, $_.Exception.Message)
        throw
    }
}

function Test-SmokeCase {
    param([Parameter(Mandatory = $true)][string]$Name)
    return [bool]($RunAllCases -or ($SelectedCases -contains $Name))
}


function Invoke-SmokeCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    if (-not (Test-SmokeCase $Name)) {
        Write-Output "prepare smoke case: SKIP name=$Name"
        return
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Write-Output "prepare smoke case: START name=$Name"
    try {
        & $Action
        $watch.Stop()
        Write-Output "prepare smoke case: PASS name=$Name duration_ms=$($watch.ElapsedMilliseconds)"
    }
    catch {
        $watch.Stop()
        Write-Output ("prepare smoke case: FAIL name={0} duration_ms={1} error={2}" -f $Name, $watch.ElapsedMilliseconds, $_.Exception.Message)
        throw
    }
}


function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "[ASSERT_FAIL] $Message" }
}

function Assert-ThrowsLike {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $caught = $null
    try { & $Action }
    catch { $caught = $_ }
    $actual = if ($null -ne $caught) { $caught.Exception.Message } else { '<no exception>' }
    Assert-True ($null -ne $caught -and $actual -match $Pattern) "$Message Actual=$actual"
}

function Assert-ProductionWslMetadataSeam {
    $witnesses = @(
        [pscustomobject]@{ RelativePath = 'main.py'; ExpectEmpty = $false },
        [pscustomobject]@{ RelativePath = 'src/core/__init__.py'; ExpectEmpty = $true }
    )
    foreach ($witness in $witnesses) {
        $relativePath = $witness.RelativePath
        $linuxPath = "$FormalBackendLinux/$relativePath"

        $direct = @(& wsl.exe -d Ubuntu --exec stat -c '%a|%u|%g|%F' -- $linuxPath 2>$null)
        $directExit = $LASTEXITCODE
        Assert-True ($directExit -eq 0 -and $direct.Count -eq 1) "Literal argv control failed. path=$linuxPath exit=$directExit count=$($direct.Count) output=$($direct -join ' | ')"
        $parts = @([string]$direct[0] -split '\|')
        Assert-True ($parts.Count -eq 4 -and @('regular file', 'regular empty file') -contains $parts[3]) "Literal argv control returned malformed metadata: $($direct -join ';')"
        $expectedMode = $parts[0]
        $expectedUid = [int]$parts[1]
        $expectedGid = [int]$parts[2]

        $sizeControl = @(& wsl.exe -d Ubuntu --exec stat -c '%s' -- $linuxPath 2>$null)
        $sizeExit = $LASTEXITCODE
        Assert-True ($sizeExit -eq 0 -and $sizeControl.Count -eq 1) "WSL size control failed. path=$linuxPath exit=$sizeExit count=$($sizeControl.Count)"
        $actualSize = [long]$sizeControl[0]
        Assert-True (($actualSize -eq 0) -eq $witness.ExpectEmpty) "Formal backend witness has the wrong empty/non-empty shape: $linuxPath"

        # This production helper call is the contract under test; the direct stat call above is only its read-only control.
        $metadata = Get-FormalPrepareWslFileMetadata -LinuxPath $linuxPath
        Assert-True ($metadata.exists -and $metadata.posix_mode -eq $expectedMode -and $metadata.uid -eq $expectedUid -and $metadata.gid -eq $expectedGid) "Production metadata helper diverged from the literal argv control: $relativePath"
    }

    $ordinary = ConvertFrom-FormalPrepareWslStat -StatOutput @('755|1000|1000|regular file') -ExitCode 0 -LinuxPath '/synthetic/ordinary'
    $emptyOrdinary = ConvertFrom-FormalPrepareWslStat -StatOutput @('755|1000|1000|regular empty file') -ExitCode 0 -LinuxPath '/synthetic/empty-ordinary'
    Assert-True ($ordinary.posix_mode -eq '755' -and $ordinary.uid -eq 1000 -and $ordinary.gid -eq 1000) 'Synthetic regular file metadata was not parsed exactly.'
    Assert-True ($emptyOrdinary.posix_mode -eq '755' -and $emptyOrdinary.uid -eq 1000 -and $emptyOrdinary.gid -eq 1000) 'Synthetic regular empty file metadata was not parsed exactly.'

    $missing = "/tmp/LaplaceSentryWslMetadataMissing-$([Guid]::NewGuid().ToString('N'))"
    Assert-ThrowsLike { Get-FormalPrepareWslFileMetadata -LinuxPath $missing } 'UPGRADE_PREPARE_SOURCE_FAIL' 'A failed production stat command was accepted.'
    Assert-ThrowsLike { Get-FormalPrepareWslFileMetadata -LinuxPath '/tmp' } 'UPGRADE_PREPARE_SOURCE_FAIL' 'A non-regular WSL path was accepted.'
    Assert-ThrowsLike { ConvertFrom-FormalPrepareWslStat -StatOutput @('755|1000|1000') -ExitCode 0 -LinuxPath '/synthetic/incomplete' } 'UPGRADE_PREPARE_SOURCE_FAIL' 'Incomplete metadata was accepted.'
    Assert-ThrowsLike { ConvertFrom-FormalPrepareWslStat -StatOutput @('755|1000|1000|directory') -ExitCode 0 -LinuxPath '/synthetic/directory' } 'UPGRADE_PREPARE_SOURCE_FAIL' 'Directory metadata was accepted.'
    Assert-ThrowsLike { ConvertFrom-FormalPrepareWslStat -StatOutput @('755|1000|1000|symbolic link') -ExitCode 0 -LinuxPath '/synthetic/symlink' } 'UPGRADE_PREPARE_SOURCE_FAIL' 'Symlink metadata was accepted.'
    Assert-ThrowsLike { ConvertFrom-FormalPrepareWslStat -StatOutput @('755|1000|1000|regular sparse file') -ExitCode 0 -LinuxPath '/synthetic/unknown' } 'UPGRADE_PREPARE_SOURCE_FAIL' 'Unknown file type metadata was accepted.'
    Assert-ThrowsLike { ConvertFrom-FormalPrepareWslStat -StatOutput @('seven|1000|1000|regular file') -ExitCode 0 -LinuxPath '/synthetic/nonnumeric' } 'UPGRADE_PREPARE_SOURCE_FAIL' 'Illegal numeric metadata was accepted.'
    Assert-ThrowsLike { ConvertFrom-FormalPrepareWslStat -StatOutput @('755|1000|1000|regular file|extra') -ExitCode 0 -LinuxPath '/synthetic/extra-field' } 'UPGRADE_PREPARE_SOURCE_FAIL' 'Extra metadata fields were accepted.'
    Assert-ThrowsLike { ConvertFrom-FormalPrepareWslStat -StatOutput @('755|1000|1000|regular file', 'extra') -ExitCode 0 -LinuxPath '/synthetic/multiple' } 'UPGRADE_PREPARE_SOURCE_FAIL' 'Multiple metadata lines were accepted.'
    Assert-ThrowsLike { ConvertFrom-FormalPrepareWslStat -StatOutput @('755|1000|1000|regular file') -ExitCode 1 -LinuxPath '/synthetic/stat-failure' } 'UPGRADE_PREPARE_SOURCE_FAIL' 'A failed stat exit code was accepted.'
}

function Assert-CheckpointBasisContract {
    $syntheticPrepareHead = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $syntheticUpgradeCoreHead = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $syntheticApplyHead = 'dddddddddddddddddddddddddddddddddddddddd'
    $syntheticInvalidatedHead = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
    $syntheticGrandchild = 'cccccccccccccccccccccccccccccccccccccccc'
    $priorRepoHead = '3f3321046a0f32691ca63ad67c887f32188b7ffc'
    $preparePaths = @('scripts/upgrade_formal_prepare.ps1', 'tests/upgrade_formal_prepare_smoke.ps1')
    $applyPaths = @('scripts/upgrade.ps1', 'scripts/upgrade_formal_apply.ps1', 'tests/upgrade_formal_apply_smoke.ps1', 'scripts/upgrade_formal_prepare.ps1', 'tests/upgrade_formal_prepare_smoke.ps1')
    $invalidatedPaths = @('scripts/upgrade_formal_prepare.ps1', 'tests/upgrade_formal_prepare_smoke.ps1')
    $upgradeCorePaths = @($FormalPrepareUpgradeCoreCheckpointPaths)
    $fixtureDirtyPaths = $upgradeCorePaths
    Assert-True ((Assert-FormalPrepareCheckpointBasis -CurrentHead $FormalPrepareRepoHead -ParentHead '' -ChangedPaths @()) -eq 'working_tree') 'Original working-tree basis was rejected.'
    Assert-True ((Assert-FormalPrepareCheckpointBasis -CurrentHead $FormalPrepareCheckpointHead -ParentHead '' -ChangedPaths @()) -eq 'checkpoint') 'Approved first checkpoint was rejected.'
    Assert-True ((Assert-FormalPrepareCheckpointBasis -CurrentHead $FormalPrepareApplyCheckpointHead -ParentHead '' -ChangedPaths @()) -eq 'checkpoint') 'Approved apply checkpoint anchor was rejected.'
    Assert-True ((Assert-FormalPrepareCheckpointBasis -CurrentHead $FormalPrepareInvalidatedCheckpointHead -ParentHead '' -ChangedPaths @()) -eq 'checkpoint') 'Approved invalidated checkpoint anchor was rejected.'
    Assert-True ((Assert-FormalPrepareCheckpointBasis -CurrentHead $FormalPrepareTestBaselineHead -ParentHead '' -ChangedPaths @()) -eq 'checkpoint') 'Decision 227 approved test baseline was rejected.'
    Assert-True ((Assert-FormalPrepareCheckpointBasis -CurrentHead $FormalPrepareUpgradeCoreCheckpointHead -ParentHead '' -ChangedPaths @()) -eq 'checkpoint') 'Decision 242 approved upgrade-core anchor was rejected.'
    Assert-True ((Assert-FormalPrepareCheckpointBasis -CurrentHead $syntheticPrepareHead -ParentHead $FormalPrepareCheckpointHead -ChangedPaths $preparePaths) -eq 'checkpoint') 'Legal direct two-file PrepareFormal checkpoint was rejected.'
    Assert-True ((Assert-FormalPrepareCheckpointBasis -CurrentHead $syntheticApplyHead -ParentHead $FormalPrepareApplyCheckpointHead -ChangedPaths $applyPaths) -eq 'checkpoint') 'Legal direct five-file ValidateFormalApply checkpoint was rejected.'
    Assert-True ((Assert-FormalPrepareCheckpointBasis -CurrentHead $syntheticInvalidatedHead -ParentHead $FormalPrepareInvalidatedCheckpointHead -ChangedPaths $invalidatedPaths) -eq 'checkpoint') 'Legal direct checkpoint-lineage repair was rejected.'
    Assert-True ((Assert-FormalPrepareCheckpointBasis -CurrentHead $syntheticUpgradeCoreHead -ParentHead $FormalPrepareUpgradeCoreCheckpointHead -ChangedPaths $upgradeCorePaths) -eq 'checkpoint') 'Legal direct five-file upgrade-core checkpoint was rejected.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead $syntheticPrepareHead -ParentHead $FormalPrepareRepoHead -ChangedPaths $preparePaths)) 'A sibling checkpoint from the original basis was accepted.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead $syntheticGrandchild -ParentHead $syntheticApplyHead -ChangedPaths $applyPaths)) 'An arbitrary checkpoint descendant was accepted.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead $syntheticGrandchild -ParentHead $syntheticInvalidatedHead -ChangedPaths $invalidatedPaths)) 'An arbitrary invalidated-checkpoint descendant was accepted.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead $syntheticGrandchild -ParentHead $syntheticUpgradeCoreHead -ChangedPaths $upgradeCorePaths)) 'An arbitrary upgrade-core grandchild was accepted.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead $syntheticPrepareHead -ParentHead $priorRepoHead -ChangedPaths (@('scripts/upgrade.ps1') + $preparePaths))) 'Prior three-file checkpoint lineage was accepted.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead $syntheticApplyHead -ParentHead ('b' * 40) -ChangedPaths $applyPaths)) 'Wrong checkpoint parent was accepted.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead $syntheticApplyHead -ParentHead $FormalPrepareApplyCheckpointHead -ChangedPaths @('scripts/upgrade.ps1'))) 'Partial apply checkpoint was accepted.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead $syntheticApplyHead -ParentHead $FormalPrepareApplyCheckpointHead -ChangedPaths ($applyPaths + 'sixth-file.txt'))) 'Apply checkpoint with an extra file was accepted.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead $syntheticApplyHead -ParentHead $FormalPrepareApplyCheckpointHead -ChangedPaths ($applyPaths | Where-Object { $_ -ne 'scripts/upgrade_formal_apply.ps1' }))) 'Apply checkpoint with a missing path was accepted.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead $syntheticInvalidatedHead -ParentHead ('b' * 40) -ChangedPaths $invalidatedPaths)) 'Checkpoint-lineage repair with a wrong parent was accepted.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead $syntheticInvalidatedHead -ParentHead $FormalPrepareInvalidatedCheckpointHead -ChangedPaths @('scripts/upgrade_formal_prepare.ps1'))) 'Checkpoint-lineage repair with a missing path was accepted.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead $syntheticInvalidatedHead -ParentHead $FormalPrepareInvalidatedCheckpointHead -ChangedPaths ($invalidatedPaths + 'third-file.txt'))) 'Checkpoint-lineage repair with an extra file was accepted.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead $syntheticUpgradeCoreHead -ParentHead ('f' * 40) -ChangedPaths $upgradeCorePaths)) 'Upgrade-core checkpoint with a wrong parent was accepted.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead $syntheticUpgradeCoreHead -ParentHead '' -ChangedPaths $upgradeCorePaths)) 'Upgrade-core merge-shaped checkpoint was accepted.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead $syntheticUpgradeCoreHead -ParentHead $FormalPrepareUpgradeCoreCheckpointHead -ChangedPaths ($upgradeCorePaths | Select-Object -Skip 1))) 'Upgrade-core checkpoint with a missing path was accepted.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead $syntheticUpgradeCoreHead -ParentHead $FormalPrepareUpgradeCoreCheckpointHead -ChangedPaths ($upgradeCorePaths + 'sixth-file.txt'))) 'Upgrade-core checkpoint with an extra path was accepted.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead $syntheticUpgradeCoreHead -ParentHead $FormalPrepareUpgradeCoreCheckpointHead -ChangedPaths (($upgradeCorePaths | Select-Object -Skip 1) + 'README.md'))) 'Upgrade-core checkpoint with a substituted path was accepted.'

    Assert-FormalPrepareRepoState -OriginMain $FormalPrepareOriginMain -Staged @() -Dirty @('.gitignore', 'Frontend/src/backend/adapter.py') -FixtureMode $false
    Assert-FormalPrepareRepoState -OriginMain $FormalPrepareOriginMain -Staged @() -Dirty ($fixtureDirtyPaths + @('.gitignore', 'Frontend/src/backend/adapter.py')) -FixtureMode $true
    Assert-ThrowsLike { Assert-FormalPrepareRepoState -OriginMain ('f' * 40) -Staged @() -Dirty @() -FixtureMode $false } 'UPGRADE_PREPARE_BASIS_FAIL' 'Wrong origin/main was accepted.'
    Assert-ThrowsLike { Assert-FormalPrepareRepoState -OriginMain $FormalPrepareOriginMain -Staged @('scripts/upgrade_formal_prepare.ps1') -Dirty @() -FixtureMode $false } 'UPGRADE_PREPARE_BASIS_FAIL' 'Staged changes were accepted.'
    Assert-ThrowsLike { Assert-FormalPrepareRepoState -OriginMain $FormalPrepareOriginMain -Staged @() -Dirty @('unexpected.txt') -FixtureMode $false } 'UPGRADE_PREPARE_BASIS_FAIL' 'Unexpected dirty path was accepted.'
}

function Assert-BranchGuardContract {
    Assert-True ((Assert-FormalPrepareMainBranch -BranchOutput 'main') -eq 'main') 'The main branch was rejected.'
    Assert-ThrowsLike { Assert-FormalPrepareMainBranch -BranchOutput $null } 'UPGRADE_PREPARE_BASIS_FAIL.*detached HEAD' 'Detached HEAD was not explicitly rejected.'
    Assert-ThrowsLike { Assert-FormalPrepareMainBranch -BranchOutput 'feature/test' } 'UPGRADE_PREPARE_BASIS_FAIL.*Expected branch main' 'A non-main branch was accepted.'
}

function Assert-CurrentHeadCheckpointBasis {
    $actualHead = (git rev-parse HEAD).Trim()
    Assert-True ((Assert-FormalPrepareCheckpointBasis -CurrentHead $actualHead) -eq 'checkpoint') 'Current HEAD was not accepted as an approved checkpoint.'
    Assert-ThrowsLike { Get-GitOutput -Arguments @('laplace-sentry-invalid-smoke-command') } 'UPGRADE_GIT_FAIL.*git laplace-sentry-invalid-smoke-command.*exit=[1-9]' 'Smoke Git bridge did not preserve a readable nonzero failure.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead ('f' * 40) -ParentHead $actualHead -ChangedPaths @('README.md'))) 'An arbitrary direct descendant of the current HEAD was accepted.'
    if (-not $actualHead.Equals($FormalPrepareUpgradeCoreCheckpointHead, [System.StringComparison]::OrdinalIgnoreCase)) {
        Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead ('f' * 40) -ParentHead $actualHead -ChangedPaths $FormalPrepareUpgradeCoreCheckpointPaths)) 'A deeper five-file descendant of the upgrade-core checkpoint was accepted.'
    }
    Write-Output ('prepare current-head basis: PASS head=' + $actualHead + ' checked=true')
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

function New-PrepareHarnessEntryScript {
    param([Parameter(Mandatory = $true)]$Case)
    $entry = Join-Path $Case.Root 'prepare-harness-entry.ps1'
    Assert-StrictTempPath $entry
    $repoLiteral = $RepoRoot.Replace("'", "''")
    $content = @"
[CmdletBinding()]
param(
    [ValidateSet('PrepareFormal')]
    [string]`$Mode = 'PrepareFormal',

    [string]`$IsolationRoot,
    [string]`$TransactionRoot,
    [string]`$FrontendTarget,
    [string]`$BackendTarget,
    [string]`$PreflightObservationPath,

    [ValidateSet('None', 'Preimage', 'Package', 'Prepare', 'Journal', 'SecondSnapshot', 'EvidenceTamper')]
    [string]`$MixedFailureInjection = 'None'
)

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'

`$RepoRoot = '$repoLiteral'
`$PrepareScript = Join-Path `$RepoRoot 'scripts\upgrade_formal_prepare.ps1'
`$UpgradeScript = Join-Path `$RepoRoot 'scripts\upgrade.ps1'

# Import the shared formal prepare constants from the production helper, then
# publish them to this child process so helper functions invoked through
# upgrade.ps1 do not depend on a second target truth in the smoke test.
. `$PrepareScript
foreach (`$variable in @(Get-Variable -Name 'FormalPrepare*','FormalUpgradeTargetCommit' -ErrorAction SilentlyContinue)) {
    Set-Variable -Scope Global -Name `$variable.Name -Value `$variable.Value
}

`$invokeParams = @{
    Mode = `$Mode
    IsolationRoot = `$IsolationRoot
    TransactionRoot = `$TransactionRoot
    FrontendTarget = `$FrontendTarget
    BackendTarget = `$BackendTarget
    PreflightObservationPath = `$PreflightObservationPath
    MixedFailureInjection = `$MixedFailureInjection
}
& `$UpgradeScript @invokeParams
exit `$LASTEXITCODE
"@
    $content | Set-Content -LiteralPath $entry -Encoding UTF8
    return $entry
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

function Initialize-PrepareTemplate {
    $build = Join-Path $TemplateRoot 'fixture-build'
    $tree = Join-Path $build 'target'
    $oldTree = Join-Path $build 'old-adapter'
    New-Item -ItemType Directory -Path $TemplateRoot -Force | Out-Null
    $specs = @($FrontendAllowlist | ForEach-Object { 'Frontend/' + $_ }) + @($BackendAllowlist | ForEach-Object { 'Backend/' + $_ })
    Export-CommitTree -Commit $TargetCommit -PathSpecs $specs -Destination $tree -WorkRoot (Join-Path $build 'target-archive')
    Export-CommitTree -Commit $AdapterCommit -PathSpecs @('Frontend/src/backend/adapter.py') -Destination $oldTree -WorkRoot (Join-Path $build 'old-archive')
    $frontend = Join-Path $TemplateRoot 'frontend-target'
    $backend = Join-Path $TemplateRoot 'backend-target'
    Move-Item -LiteralPath (Join-Path $tree 'Frontend') -Destination $frontend
    Move-Item -LiteralPath (Join-Path $tree 'Backend') -Destination $backend
    Copy-Item -LiteralPath (Join-Path $oldTree 'Frontend\src\backend\adapter.py') -Destination (Join-Path $frontend 'src\backend\adapter.py') -Force
    Remove-TestTree $build
    New-Item -ItemType Directory -Path (Join-Path $backend 'data') -Force | Out-Null
    "[General]`r`neye_size=480" | Set-Content -LiteralPath (Join-Path $frontend 'sentry_config.ini') -Encoding UTF8
    '[{"uuid":"fixture-project","name":"must-survive"}]' | Set-Content -LiteralPath (Join-Path $backend 'data\projects.json') -Encoding UTF8
    $SourceMarker | Set-Content -LiteralPath (Join-Path $frontend 'version.txt') -Encoding ASCII -NoNewline
    $SourceMarker | Set-Content -LiteralPath (Join-Path $backend 'version.txt') -Encoding ASCII -NoNewline
    $observation = Join-Path $TemplateRoot 'observation.json'
    [ordered]@{
        source_dirty = $false
        tracked_deletions = @()
        requirements_changes = @()
        force_non_ancestor = $false
        protected_unreadable = @()
        ambiguous_runtime = @()
        lock_exists = $false
        ui = @()
        daemon = @()
        workers = @()
        registry = @([ordered]@{ pid = 114348; uuid = 'fixture-stale'; proc_exists = $false; owned = $false; uuid_matches = $false; ambiguous = $false })
        transaction_acl_ok = $true
        transaction_owner_ok = $true
        free_bytes = [int64](4GB)
        fixture_backend_mode = '755'
        fixture_backend_uid = 1000
        fixture_backend_gid = 1000
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $observation -Encoding UTF8
    foreach ($file in @(Get-ChildItem -LiteralPath $frontend, $backend -Recurse -File -Force)) { [IO.File]::SetLastWriteTimeUtc($file.FullName, $FixedTime) }
    [IO.File]::SetLastWriteTimeUtc($observation, $FixedTime)
}

function New-PrepareCase {
    param([Parameter(Mandatory = $true)][string]$Name)
    $root = Join-Path $SuiteRoot $Name
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $TemplateRoot 'frontend-target') -Destination (Join-Path $root 'frontend-target') -Recurse
    Copy-Item -LiteralPath (Join-Path $TemplateRoot 'backend-target') -Destination (Join-Path $root 'backend-target') -Recurse
    Copy-Item -LiteralPath (Join-Path $TemplateRoot 'observation.json') -Destination (Join-Path $root 'observation.json')
    $frontend = Join-Path $root 'frontend-target'
    $backend = Join-Path $root 'backend-target'
    $observation = Join-Path $root 'observation.json'
    $case = [pscustomobject]@{
        Name = $Name
        Root = $root
        Frontend = $frontend
        Backend = $backend
        Transactions = Join-Path $root 'transactions'
        Observation = $observation
        Adapter = Join-Path $frontend 'src\backend\adapter.py'
        Tray = Join-Path $frontend 'src\tray\tray_app.py'
        FrontendMarker = Join-Path $frontend 'version.txt'
        BackendMarker = Join-Path $backend 'version.txt'
        Config = Join-Path $frontend 'sentry_config.ini'
        Projects = Join-Path $backend 'data\projects.json'
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $frontend, $backend -Recurse -File -Force)) { [IO.File]::SetLastWriteTimeUtc($file.FullName, $FixedTime) }
    [IO.File]::SetLastWriteTimeUtc($observation, $FixedTime)
    return $case
}

function Write-CaseObservation {
    param([Parameter(Mandatory = $true)]$Case, [Parameter(Mandatory = $true)]$Observation)
    $Observation | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Case.Observation -Encoding UTF8
    [IO.File]::SetLastWriteTimeUtc($Case.Observation, $FixedTime)
}

function Get-CaseTargetCanonical {
    param([Parameter(Mandatory = $true)]$Case)
    $lines = @()
    foreach ($gitPath in Get-ExpectedManagedPaths) {
        $side = if ($gitPath.StartsWith('Frontend/')) { 'Frontend' } else { 'Backend' }
        $relative = $gitPath.Substring($side.Length + 1)
        $root = if ($side -eq 'Frontend') { $Case.Frontend } else { $Case.Backend }
        $path = Join-Path $root $relative.Replace('/', '\')
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $item = Get-Item -LiteralPath $path -Force
            $lines += "$gitPath|1|$($item.Length)|$($item.LastWriteTimeUtc.ToString('o'))|$(Get-Sha $path)"
        }
        else { $lines += "$gitPath|0|-|-|-" }
    }
    foreach ($spec in @(
        @('Frontend/version.txt', $Case.FrontendMarker), @('Backend/version.txt', $Case.BackendMarker),
        @('Frontend/sentry_config.ini', $Case.Config), @('Backend/data/projects.json', $Case.Projects)
    )) {
        $item = Get-Item -LiteralPath $spec[1] -Force
        $lines += "$($spec[0])|1|$($item.Length)|$($item.LastWriteTimeUtc.ToString('o'))|$(Get-Sha $spec[1])"
    }
    return @($lines | Sort-Object) -join "`n"
}

function Get-TreeCanonical {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'ABSENT' }
    $lines = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($Path.Length).TrimStart('\').Replace('\', '/')
        $lines += "$relative|$($file.Length)|$($file.LastWriteTimeUtc.ToString('o'))|$(Get-Sha $file.FullName)"
    }
    return @($lines) -join "`n"
}

function Get-FormalBoundaryCanonical {
    $parts = @()
    foreach ($gitPath in Get-ExpectedManagedPaths) {
        $side = if ($gitPath.StartsWith('Frontend/')) { 'Frontend' } else { 'Backend' }
        $relative = $gitPath.Substring($side.Length + 1)
        $root = if ($side -eq 'Frontend') { $FormalFrontend } else { $FormalBackend }
        $path = Join-Path $root $relative.Replace('/', '\')
        try {
            if ($side -eq 'Backend') {
                $linuxPath = '/home/serpal/.laplace_sentry_backend/' + $relative
                & wsl.exe -d Ubuntu -- test -f $linuxPath
                if ($LASTEXITCODE -eq 0) {
                    $stat = @(& wsl.exe -d Ubuntu -- stat -c '%s' -- $linuxPath)
                    $hash = @(& wsl.exe -d Ubuntu -- sha256sum -- $linuxPath)
                    Assert-True ($LASTEXITCODE -eq 0 -and $stat.Count -eq 1 -and $hash.Count -eq 1) "Unable to hash formal backend path: $linuxPath"
                    $parts += "$gitPath|1|$($stat[0].Trim())|$((($hash[0] -split '\s+')[0]).ToUpperInvariant())"
                }
                else { $parts += "$gitPath|0|-|-" }
            }
            elseif (Test-Path -LiteralPath $path -PathType Leaf) {
                $item = Get-Item -LiteralPath $path -Force
                $parts += "$gitPath|1|$($item.Length)|$(Get-Sha $path)"
            }
            else { $parts += "$gitPath|0|-|-" }
        }
        catch { throw "Formal boundary read failed for $gitPath at $path`: $($_.Exception.Message)" }
    }
    foreach ($spec in @(
        @('Frontend/version.txt', (Join-Path $FormalFrontend 'version.txt')),
        @('Frontend/sentry_config.ini', (Join-Path $FormalFrontend 'sentry_config.ini')),
        @('Backend/version.txt', '/home/serpal/.laplace_sentry_backend/version.txt'),
        @('Backend/data/projects.json', '/home/serpal/.laplace_sentry_backend/data/projects.json')
    )) {
        if ($spec[0].StartsWith('Backend/')) {
            & wsl.exe -d Ubuntu -- test -f $spec[1]
            if ($LASTEXITCODE -eq 0) {
                $stat = @(& wsl.exe -d Ubuntu -- stat -c '%s' -- $spec[1])
                $hash = @(& wsl.exe -d Ubuntu -- sha256sum -- $spec[1])
                Assert-True ($LASTEXITCODE -eq 0 -and $stat.Count -eq 1 -and $hash.Count -eq 1) "Unable to hash formal backend protected path: $($spec[1])"
                $parts += "$($spec[0])|1|$($stat[0].Trim())|$((($hash[0] -split '\s+')[0]).ToUpperInvariant())"
            }
            else { $parts += "$($spec[0])|0|-|-" }
        }
        elseif (Test-Path -LiteralPath $spec[1] -PathType Leaf) {
            $item = Get-Item -LiteralPath $spec[1] -Force
            $parts += "$($spec[0])|1|$($item.Length)|$(Get-Sha $spec[1])"
        }
        else { $parts += "$($spec[0])|0|-|-" }
    }
    $parts += "formal-transactions|$(Get-TreeCanonical $FormalTransactions)"
    return @($parts | Sort-Object) -join "`n"
}

function Stop-PrepareChildProcess {
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    # 防止 timeout 後只殺 parent、把 child Git 或 host process 留給下一個 case。
    $childIds = @()
    try {
        $childIds = @(Get-CimInstance Win32_Process -ErrorAction Stop |
            Where-Object { $_.ParentProcessId -eq $Process.Id } |
            Select-Object -ExpandProperty ProcessId)
    }
    catch {}
    foreach ($childId in $childIds) {
        Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue
    }
    if (-not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-PrepareProcess {
    param(
        [Parameter(Mandatory = $true)]$Case,
        [string]$Injection = 'None',
        [string]$Frontend = $Case.Frontend,
        [string]$Backend = $Case.Backend,
        [string]$Transactions = $Case.Transactions,
        [string]$Observation = $Case.Observation,
        [string]$IsolationRoot = $Case.Root,
        [int]$TimeoutMilliseconds = 60000
    )
    $harnessEntry = New-PrepareHarnessEntryScript -Case $Case
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-Argument $harnessEntry),
        '-Mode', 'PrepareFormal',
        '-IsolationRoot', (Quote-Argument $IsolationRoot),
        '-TransactionRoot', (Quote-Argument $Transactions),
        '-FrontendTarget', (Quote-Argument $Frontend),
        '-BackendTarget', (Quote-Argument $Backend),
        '-PreflightObservationPath', (Quote-Argument $Observation),
        '-MixedFailureInjection', $Injection
    ) -join ' '
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
        $stdoutDone = $stdoutTask.IsCompleted
        $stderrDone = $stderrTask.IsCompleted
        Stop-PrepareChildProcess -Process $process
        throw "[PREPARE_CHILD_TIMEOUT] case=$($Case.Name) timeout_ms=$TimeoutMilliseconds pid=$($process.Id) command=$($startInfo.FileName) stdout_done=$stdoutDone stderr_done=$stderrDone"
    }
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $json = $null
    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        try { $json = $stdout.Trim() | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "[$($Case.Name)] stdout was not one JSON document. stdout=$stdout stderr=$stderr" }
    }
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Json = $json; Stdout = $stdout; Stderr = $stderr }
}

function Assert-NoTransactionDirectory {
    param([Parameter(Mandatory = $true)]$Case)
    $count = if (Test-Path -LiteralPath $Case.Transactions) { @(Get-ChildItem -LiteralPath $Case.Transactions -Directory -Force).Count } else { 0 }
    Assert-True ($count -eq 0) "[$($Case.Name)] rejection created a transaction directory."
}

function Assert-RejectedBeforeTransaction {
    param([string]$Name, [scriptblock]$Mutate, [hashtable]$InvokeOverrides = @{})
    Invoke-SmokeCase $Name {
        $case = New-PrepareCase $Name
        $observation = Get-Content -LiteralPath $case.Observation -Raw -Encoding UTF8 | ConvertFrom-Json
        & $Mutate $case $observation
        Write-CaseObservation -Case $case -Observation $observation
        $before = Get-CaseTargetCanonical $case
        $parameters = @{ Case = $case }
        foreach ($key in $InvokeOverrides.Keys) { $parameters[$key] = $InvokeOverrides[$key] }
        $result = Invoke-PrepareProcess @parameters
        Assert-True ($result.ExitCode -eq 6) "[$Name] expected exit 6. stderr=$($result.Stderr)"
        Assert-True ($result.Json.result -eq 'failed' -and $result.Json.state -eq 'rejected') "[$Name] pre-transaction result was not an explicit rejection."
        Assert-True ($result.Json.failure_phase -eq 'before_transaction' -and -not $result.Json.transaction_id -and -not $result.Json.transaction_root) "[$Name] rejection exposed the wrong transaction phase."
        Assert-NoTransactionDirectory $case
        Assert-True ((Get-CaseTargetCanonical $case) -ceq $before) "[$Name] changed fixture targets."
    }
}



function Assert-InvalidatedZeroWrites {
    param([string]$Name, [string]$Injection)
    Invoke-SmokeCase $Name {
        $case = New-PrepareCase $Name
        $before = Get-CaseTargetCanonical $case
        $result = Invoke-PrepareProcess -Case $case -Injection $Injection
        Assert-True ($result.ExitCode -eq 6) "[$Name] expected exit 6 for $Injection. stderr=$($result.Stderr)"
        Assert-True ((Get-CaseTargetCanonical $case) -ceq $before) "[$Name] changed fixture targets."
        $journals = @(Get-ChildItem -LiteralPath $case.Transactions -Recurse -File -Filter 'transaction-journal.json')
        Assert-True ($journals.Count -eq 1) "[$Name] did not preserve one journal."
        $journal = Get-Content -LiteralPath $journals[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($journal.state -eq 'prepare_invalidated') "[$Name] state was not prepare_invalidated."
        Assert-True ($result.Json.state -eq $journal.state -and $result.Json.result -eq $journal.result) "[$Name] stdout state/result diverged from journal."
        Assert-True ($result.Json.failure_phase -eq 'after_transaction' -and $result.Json.failure_phase -eq $journal.failure_phase) "[$Name] stdout did not identify an after-transaction failure."
        Assert-True ($result.Json.transaction_id -eq $journal.transaction_id -and $result.Json.transaction_root -eq $journal.transaction_root) "[$Name] stdout transaction identity diverged from journal."
        Assert-True ($result.Json.error -eq $journal.error) "[$Name] stdout error diverged from journal."
        Assert-True ([int]$journal.formal_target_write_count -eq 0) "[$Name] formal write count was not zero."
    }
}



try {
    Write-Output "upgrade formal prepare smoke: SELECTED groups=$($SelectedGroups -join ',')"
    Assert-CheckpointBasisContract
    Assert-BranchGuardContract
    # 真實 HEAD 是所有 selector 的共同安全前置；不得只在 basis-only 的提前退出分支中執行。
    Assert-CurrentHeadCheckpointBasis
    # `all` 會讓 Test-SmokeGroup 對每組回傳 true；只有明確單選 basis-only 才可提前退出。
    if ($SelectedGroups.Count -eq 1 -and $SelectedGroups -contains 'basis-only') {
        $actualHead = (git rev-parse HEAD).Trim()
        Write-Output "prepare basis-only: PASS head=$actualHead temp_fixture=false wsl_metadata=false"
        exit 0
    }
    Assert-StrictTempPath $SuiteRoot
    Assert-StrictTempPath $OutsideRoot
    New-Item -ItemType Directory -Path $SuiteRoot, $OutsideRoot -Force | Out-Null
    Initialize-PrepareTemplate

    # 先單獨驗證 literal argv seam，避免正式邊界大量唯讀 WSL fingerprint 呼叫掩蓋此契約的原始結果。
    Invoke-SmokeGroup 'metadata' { Assert-ProductionWslMetadataSeam }

    if (Test-SmokeGroup 'formal-boundary') {
        $script:FormalBefore = @(Get-FormalBoundaryCanonical) -join "`n"
    }

    Invoke-SmokeGroup 'success' {
        Invoke-SmokeCase 'success-and-rerun' {
            $success = New-PrepareCase 'success-and-rerun'
            $targetBefore = Get-CaseTargetCanonical $success
            $prepared = Invoke-PrepareProcess -Case $success
            Assert-True ($prepared.ExitCode -eq 0 -and $prepared.Json.result -eq 'prepared') "Success prepare failed. stderr=$($prepared.Stderr)"
            Assert-True ($prepared.Json.state -eq 'prepared_pending_apply' -and [int]$prepared.Json.formal_target_write_count -eq 0) 'Success state/write count mismatch.'
            Assert-True ((Get-CaseTargetCanonical $success) -ceq $targetBefore) 'Success prepare changed fixture targets.'
            $transactionDirs = @(Get-ChildItem -LiteralPath $success.Transactions -Directory -Force)
            Assert-True ($transactionDirs.Count -eq 1) 'Success did not create exactly one transaction.'
            $journal = Get-Content -LiteralPath (Join-Path $transactionDirs[0].FullName 'transaction-journal.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $sourceManifest = Get-Content -LiteralPath $journal.manifests.source.path -Raw -Encoding UTF8 | ConvertFrom-Json
            $preimageManifest = Get-Content -LiteralPath $journal.manifests.preimage.path -Raw -Encoding UTF8 | ConvertFrom-Json
            $packageManifest = Get-Content -LiteralPath $journal.manifests.package.path -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-True ($journal.schema -eq 'laplace-formal-prepare-v1') 'Journal schema mismatch.'
            Assert-True ($journal.target_commit -eq $TargetCommit) 'Prepare journal target_commit did not use the shared formal target.'
            $packageMarkers = @($packageManifest.records | Where-Object { $_.key -in @('Backend/version.txt', 'Frontend/version.txt') })
            Assert-True ($packageMarkers.Count -eq 2) 'Package manifest must contain both version marker records.'
            foreach ($marker in $packageMarkers) {
                Assert-True (((Get-Content -LiteralPath $marker.artifact_path -Raw -Encoding UTF8).Trim()) -ceq $TargetShort) "Package marker $($marker.key) did not use the shared formal target short hash."
            }
            Assert-True (@($sourceManifest.records).Count -eq 31) 'Source manifest must contain 30 target records plus runtime observation.'
            Assert-True (@($preimageManifest.records).Count -eq 30) 'Preimage manifest must contain 30 records.'
            Assert-True (@($packageManifest.records).Count -eq 28) 'Package manifest must contain 26 files and two markers.'
            $frontendMetadata = @($sourceManifest.records | Where-Object { $_.key -eq 'Frontend/src/tray/tray_app.py' })[0]
            $backendMetadata = @($sourceManifest.records | Where-Object { $_.key -eq 'Backend/src/core/daemon.py' })[0]
            Assert-True ($frontendMetadata.attributes -and $frontendMetadata.sddl) 'Frontend attributes/SDDL were not sealed.'
            Assert-True ($backendMetadata.posix_mode -eq '755' -and $backendMetadata.uid -eq 1000 -and $backendMetadata.gid -eq 1000) 'Backend POSIX metadata was not sealed.'
            $runtimeEvidence = @($sourceManifest.records | Where-Object { $_.key -eq 'Runtime/observation.json' })[0]
            Assert-True ($runtimeEvidence.sha256 -and $runtimeEvidence.observation.registry.Count -eq 1) 'Runtime/registry observation was not sealed.'
            Assert-True (@($journal.warnings | Where-Object { $_.tag -eq '[UPGRADE_REGISTRY_STALE]' }).Count -eq 1) 'Stale registry warning was not preserved.'
            Assert-True (@(Get-ChildItem -LiteralPath $success.Frontend, $success.Backend -Recurse -File -Filter '*.tmp').Count -eq 0) 'Adjacent target temp file exists.'
            $transactionBeforeRerun = Get-TreeCanonical $success.Transactions
            $already = Invoke-PrepareProcess -Case $success
            Assert-True ($already.ExitCode -eq 0 -and $already.Json.result -eq 'already_prepared') 'Identical rerun was not already_prepared.'
            Assert-True ((Get-TreeCanonical $success.Transactions) -ceq $transactionBeforeRerun) 'already_prepared changed transaction evidence.'
        }
    }

    Invoke-SmokeGroup 'runtime-rejection' {
        Assert-RejectedBeforeTransaction 'active-lock' { param($c, $o) $o.lock_exists = $true }
        Assert-RejectedBeforeTransaction 'owned-ui' { param($c, $o) $o.ui = @([pscustomobject]@{ pid = 1; owned = $true; ambiguous = $false }) }
        Assert-RejectedBeforeTransaction 'owned-daemon' { param($c, $o) $o.daemon = @([pscustomobject]@{ pid = 2; owned = $true; ambiguous = $false }) }
        Assert-RejectedBeforeTransaction 'owned-worker' { param($c, $o) $o.workers = @([pscustomobject]@{ pid = 3; owned = $true; registered = $true; ambiguous = $false }) }
        Assert-RejectedBeforeTransaction 'ambiguous-runtime' { param($c, $o) $o.registry = @([pscustomobject]@{ pid = 4; proc_exists = $true; owned = $false; uuid_matches = $false; ambiguous = $true }) }
    }

    Invoke-SmokeGroup 'acl-rejection' {
        Assert-RejectedBeforeTransaction 'acl-reject' { param($c, $o) $o.transaction_acl_ok = $false }
        Assert-RejectedBeforeTransaction 'owner-reject' { param($c, $o) $o.transaction_owner_ok = $false }
        Assert-RejectedBeforeTransaction 'space-reject' { param($c, $o) $o.free_bytes = 1 }
    }

    Invoke-SmokeGroup 'source-rejection' {
        Assert-RejectedBeforeTransaction 'adapter-drift' { param($c, $o) 'drift' | Add-Content -LiteralPath $c.Adapter -Encoding UTF8 }
        Assert-RejectedBeforeTransaction 'tray-drift' { param($c, $o) 'drift' | Add-Content -LiteralPath $c.Tray -Encoding UTF8 }
        Assert-RejectedBeforeTransaction 'marker-drift' { param($c, $o) 'wrong' | Set-Content -LiteralPath $c.BackendMarker -Encoding ASCII -NoNewline }
    }

    Invoke-SmokeGroup 'transaction-boundary' {
        Invoke-SmokeCase 'transaction-overlap' {
            $overlap = New-PrepareCase 'transaction-overlap'
            $overlapResult = Invoke-PrepareProcess -Case $overlap -Transactions (Join-Path $overlap.Frontend 'transactions')
            Assert-True ($overlapResult.ExitCode -eq 6) 'Target/transaction overlap was not rejected.'
            Assert-NoTransactionDirectory $overlap
        }

        Invoke-SmokeCase 'transaction-unc' {
            $unc = New-PrepareCase 'transaction-unc'
            $uncResult = Invoke-PrepareProcess -Case $unc -Transactions '\\invalid-host\share\transactions'
            Assert-True ($uncResult.ExitCode -eq 6) 'UNC transaction root was not rejected.'
            Assert-NoTransactionDirectory $unc
        }

        Invoke-SmokeCase 'transaction-reparse' {
            $reparse = New-PrepareCase 'transaction-reparse'
            $script:JunctionPath = Join-Path $reparse.Root 'transactions-junction'
            New-Item -ItemType Junction -Path $script:JunctionPath -Target $OutsideRoot | Out-Null
            $reparseResult = Invoke-PrepareProcess -Case $reparse -Transactions $script:JunctionPath
            Assert-True ($reparseResult.ExitCode -eq 6) 'Reparse transaction root was not rejected.'
            Assert-True (@(Get-ChildItem -LiteralPath $OutsideRoot -Force).Count -eq 0) 'Reparse rejection wrote through the junction.'
        }
    }

    Invoke-SmokeGroup 'failure-injection' {
        foreach ($injection in @('Preimage', 'Package', 'Prepare', 'Journal', 'SecondSnapshot', 'EvidenceTamper')) {
            Assert-InvalidatedZeroWrites -Name ('inject-' + $injection.ToLowerInvariant()) -Injection $injection
        }
    }

    Invoke-SmokeGroup 'reentry-cleanup' {
        Invoke-SmokeCase 'incomplete-rerun' {
            $incomplete = New-PrepareCase 'incomplete-rerun'
            $firstIncomplete = Invoke-PrepareProcess -Case $incomplete -Injection Prepare
            Assert-True ($firstIncomplete.ExitCode -eq 6) 'Injected incomplete prepare did not fail.'
            $countBeforeIncompleteRerun = @(Get-ChildItem -LiteralPath $incomplete.Transactions -Directory -Force).Count
            $secondIncomplete = Invoke-PrepareProcess -Case $incomplete
            Assert-True ($secondIncomplete.ExitCode -eq 6 -and $secondIncomplete.Stderr -match 'UPGRADE_PREPARE_RECOVERY_REQUIRED') 'Incomplete transaction did not hard-block reentry.'
            Assert-True (@(Get-ChildItem -LiteralPath $incomplete.Transactions -Directory -Force).Count -eq $countBeforeIncompleteRerun) 'Incomplete reentry created another transaction.'
        }

        Invoke-SmokeCase 'evidence-tamper-rerun' {
            $tamper = New-PrepareCase 'evidence-tamper-rerun'
            $tamperPrepared = Invoke-PrepareProcess -Case $tamper
            Assert-True ($tamperPrepared.ExitCode -eq 0) 'Tamper setup prepare failed.'
            $tamperJournal = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $tamper.Transactions -Recurse -File -Filter transaction-journal.json).FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $tamperPackage = Get-Content -LiteralPath $tamperJournal.manifests.package.path -Raw -Encoding UTF8 | ConvertFrom-Json
            'external-tamper' | Add-Content -LiteralPath $tamperPackage.records[0].artifact_path -Encoding UTF8
            $tamperCount = @(Get-ChildItem -LiteralPath $tamper.Transactions -Directory -Force).Count
            $tamperRerun = Invoke-PrepareProcess -Case $tamper
            Assert-True ($tamperRerun.ExitCode -eq 6 -and $tamperRerun.Stderr -match 'UPGRADE_PREPARE_RECOVERY_REQUIRED') 'Tampered evidence did not block reentry.'
            Assert-True (@(Get-ChildItem -LiteralPath $tamper.Transactions -Directory -Force).Count -eq $tamperCount) 'Tampered reentry created another transaction.'
        }

        Invoke-SmokeCase 'multiple-transactions' {
            $multiple = New-PrepareCase 'multiple-transactions'
            $multiplePrepared = Invoke-PrepareProcess -Case $multiple
            Assert-True ($multiplePrepared.ExitCode -eq 0) 'Multiple setup prepare failed.'
            $originalTransaction = @(Get-ChildItem -LiteralPath $multiple.Transactions -Directory -Force)[0]
            Copy-Item -LiteralPath $originalTransaction.FullName -Destination (Join-Path $multiple.Transactions 'duplicate-prepared') -Recurse
            $multipleCount = @(Get-ChildItem -LiteralPath $multiple.Transactions -Directory -Force).Count
            $multipleRerun = Invoke-PrepareProcess -Case $multiple
            Assert-True ($multipleRerun.ExitCode -eq 6 -and $multipleRerun.Stderr -match 'UPGRADE_PREPARE_RECOVERY_REQUIRED') 'Multiple/corrupt prepared transactions did not block reentry.'
            Assert-True (@(Get-ChildItem -LiteralPath $multiple.Transactions -Directory -Force).Count -eq $multipleCount) 'Multiple reentry created another transaction.'
        }
    }

    Invoke-SmokeGroup 'formal-boundary' {
        $upgradeBatText = Get-Content -LiteralPath $UpgradeBat -Raw -Encoding UTF8
        Assert-True ($upgradeBatText -notmatch 'PrepareFormal|prepare') 'upgrade.bat publicly exposes PrepareFormal.'
        $formalAfter = @(Get-FormalBoundaryCanonical) -join "`n"
        Assert-True ($formalAfter -ceq $script:FormalBefore) 'Formal Windows/WSL targets or formal transaction root changed.'
    }

    Remove-TestTree $SuiteRoot
    if ($JunctionPath -and (Test-Path -LiteralPath $JunctionPath)) { Remove-Item -LiteralPath $JunctionPath -Force }
    Remove-TestTree $OutsideRoot
    Assert-True (-not (Test-Path -LiteralPath $SuiteRoot)) 'Suite TEMP residue remains.'
    Assert-True (-not (Test-Path -LiteralPath $OutsideRoot)) 'Outside TEMP residue remains.'
    Write-Output 'upgrade formal prepare smoke: PASS'
    exit 0
}catch {
    [Console]::Error.WriteLine("upgrade formal prepare smoke: FAIL: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))")
    try {
        if ($JunctionPath -and (Test-Path -LiteralPath $JunctionPath)) { Remove-Item -LiteralPath $JunctionPath -Force }
        if (Test-Path -LiteralPath $SuiteRoot) { Remove-TestTree $SuiteRoot }
        if (Test-Path -LiteralPath $OutsideRoot) { Remove-TestTree $OutsideRoot }
    }
    catch { [Console]::Error.WriteLine("cleanup failure: $($_.Exception.Message)") }
    exit 1
}
