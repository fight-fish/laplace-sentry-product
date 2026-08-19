[CmdletBinding()]
param(
    [switch]$SkipPython,
    [switch]$SkipTempIntegration,
    [ValidateRange(10, 600)]
    [int]$TempIntegrationTimeoutSeconds = 60
)

<#
.SYNOPSIS
執行快速升級安全檢查。

.DESCRIPTION
用途：讓日常測試入口同時執行 Python 合約測試，以及一小部分明確限定的 PowerShell 升級防護檢查。

輸入內容包括：
- 專案儲存庫中的檔案
- unittest 自動探索測試
- PowerShell 語法解析器
- 靜態升級契約檢查
- 一次嚴格限制在 TEMP 目錄內的隔離升級演練
- 一個快速的 Preflight 輔助函式契約測試
- 一個簡短的 Preflight 路徑邊界代表案例
    （除非使用參數略過）

輸出內容：
- PASS／FAIL 結果行
- 明確列出本輪沒有執行的大型測試與正式環境檢查

單一真實來源輸出（SSOT Output）：
以程序結束碼為準；結束碼為 0，表示所有 Quick Gate 檢查皆已通過。

結束碼：
- 0：通過
- 1：Quick Gate 失敗

略過條件（SKIP conditions）：
- 可以使用 `-SkipPython` 略過 Python 測試。
- 可以使用 `-SkipTempIntegration` 略過 TEMP 整合測試。
- 但輸出中必須明確說明哪些測試被略過。

失敗條件（FAIL conditions）：
以下任一情況發生時，Quick Gate 即判定失敗：
- PowerShell 語法解析錯誤
- Target／Dispatch／Selector 契約損壞
- Python 測試失敗
- TEMP 整合測試失敗
- Preflight 輔助函式契約測試失敗
- Preflight 代表案例失敗
- 測試逾時
- TEMP 目錄中留下未清除的殘留資料

副作用（Side effects）：
只有被委派執行的 TEMP 整合測試，會在系統 TEMP 目錄下建立並刪除已驗證的子目錄。

此執行器本身絕不會碰觸：
- 正式執行環境副本
- Git
- 正式交易根目錄
#>
# 這支腳本在做什麼：提供可複製的 upgrade quick gate，避免 PowerShell upgrade 防線被全域測試入口漏跑。
# 這支腳本不做什麼：不跑 heavy matrix、不做 formal read-only、不刪測試、不改產品、不碰 Git。
# 常改區塊：quick gate 納入的檔案清單與最小 contract 斷言。
# 不要亂動的區塊：未跑項目揭露、TEMP residue 檢查、正式副本禁止邊界。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Failed = $false

$PowerShellUpgradeFiles = @(
    'scripts\upgrade.ps1',
    'scripts\upgrade_formal_prepare.ps1',
    'scripts\upgrade_formal_apply.ps1',
    'scripts\upgrade_formal_invalidate.ps1',
    'tests\upgrade_formal_prepare_smoke.ps1',
    'tests\upgrade_formal_apply_smoke.ps1',
    'tests\upgrade_formal_invalidate_smoke.ps1',
    'tests\upgrade_formal_preflight_smoke.ps1',
    'tests\upgrade_formal_preflight_contract.ps1',
    'tests\upgrade_mixed_repair_smoke.ps1',
    'tests\upgrade_isolated_apply_smoke.ps1',
    'tests\upgrade_isolated_smoke.ps1',
    'tests\run_upgrade_quick_gate.ps1'
)

function Write-GateLine {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Detail = ''
    )
    if ([string]::IsNullOrWhiteSpace($Detail)) {
        Write-Output "upgrade quick gate: $Status name=$Name"
    }
    else {
        Write-Output "upgrade quick gate: $Status name=$Name detail=$Detail"
    }
}

function Invoke-GateCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Write-GateLine -Status 'START' -Name $Name
    try {
        & $Action
        $watch.Stop()
        Write-GateLine -Status 'PASS' -Name $Name -Detail "duration_ms=$($watch.ElapsedMilliseconds)"
    }
    catch {
        $watch.Stop()
        $script:Failed = $true
        Write-GateLine -Status 'FAIL' -Name $Name -Detail "duration_ms=$($watch.ElapsedMilliseconds) error=$($_.Exception.Message)"
    }
}

function Get-RepoPath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    return (Join-Path $RepoRoot $RelativePath)
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-FileExists {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    $path = Get-RepoPath $RelativePath
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Missing file: $RelativePath"
}

function Assert-NoTempResidue {
    $patterns = @(
        'LaplaceSentryUpgradeTest_*',
        'LaplaceSentryFormalPreflightSmoke-*',
        'LaplaceSentryFormalPrepareSmoke-*',
        'LaplaceSentryFormalApplySmoke-*',
        'LaplaceSentryMixedRepairSmoke-*'
    )
    $leftovers = @(Get-ChildItem -LiteralPath $env:TEMP -Directory -ErrorAction SilentlyContinue | Where-Object {
        $name = $_.Name
        foreach ($pattern in $patterns) {
            if ($name -like $pattern) { return $true }
        }
        return $false
    })
    Assert-True ($leftovers.Count -eq 0) ("TEMP residue remains: " + (($leftovers | Select-Object -ExpandProperty FullName) -join '; '))
}

function Invoke-ExternalProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FileName
    $psi.Arguments = $Arguments
    $psi.WorkingDirectory = $RepoRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    [void]$process.Start()

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { }
        throw "Timed out after ${TimeoutSeconds}s: $FileName $Arguments"
    }

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    if (-not [string]::IsNullOrWhiteSpace($stdout)) { Write-Output $stdout.TrimEnd() }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { [Console]::Error.WriteLine($stderr.TrimEnd()) }
    Assert-True ($process.ExitCode -eq 0) "External process failed exit=$($process.ExitCode): $FileName $Arguments"
}

Invoke-GateCheck 'repo files present' {
    foreach ($relativePath in $PowerShellUpgradeFiles) {
        Assert-FileExists $relativePath
    }
    Assert-FileExists 'tests\test_tree_query_contract.py'
}

Invoke-GateCheck 'PowerShell parser for upgrade scripts and tests' {
    foreach ($relativePath in $PowerShellUpgradeFiles) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile((Get-RepoPath $relativePath), [ref]$tokens, [ref]$errors)
        Assert-True ($errors.Count -eq 0) ("Parser errors in ${relativePath}: " + (($errors | ForEach-Object { $_.Message }) -join '; '))
    }
}

Invoke-GateCheck 'formal target commit single-source contract' {
    $prepareText = Get-Content -LiteralPath (Get-RepoPath 'scripts\upgrade_formal_prepare.ps1') -Raw -Encoding UTF8
    Assert-True ($prepareText -match '(?m)^\$FormalUpgradeTargetCommit\s*=\s*''[0-9a-f]{40}''') 'scripts\upgrade_formal_prepare.ps1 does not declare a single 40-char FormalUpgradeTargetCommit.'

    foreach ($relativePath in @(
        'scripts\upgrade.ps1',
        'scripts\upgrade_formal_apply.ps1',
    'scripts\upgrade_formal_invalidate.ps1',
        'tests\upgrade_formal_prepare_smoke.ps1',
        'tests\upgrade_formal_apply_smoke.ps1',
    'tests\upgrade_formal_invalidate_smoke.ps1',
        'tests\upgrade_mixed_repair_smoke.ps1'
    )) {
        $text = Get-Content -LiteralPath (Get-RepoPath $relativePath) -Raw -Encoding UTF8
        Assert-True ($text -notmatch '(?m)^\s*\$FormalUpgradeTargetCommit\s*=') "${relativePath} defines a second FormalUpgradeTargetCommit."
    }

    foreach ($relativePath in @(
        'scripts\upgrade.ps1',
        'tests\upgrade_formal_prepare_smoke.ps1',
        'tests\upgrade_formal_apply_smoke.ps1',
    'tests\upgrade_formal_invalidate_smoke.ps1',
        'tests\upgrade_mixed_repair_smoke.ps1'
    )) {
        $text = Get-Content -LiteralPath (Get-RepoPath $relativePath) -Raw -Encoding UTF8
        Assert-True ($text -match 'upgrade_formal_prepare\.ps1') "${relativePath} is not visibly connected to upgrade_formal_prepare.ps1."
    }
}

Invoke-GateCheck 'public dispatch and formal mode boundary' {
    $upgradeBatText = Get-Content -LiteralPath (Get-RepoPath 'upgrade.bat') -Raw -Encoding UTF8
    Assert-True ($upgradeBatText -match '--dry-run') 'upgrade.bat does not expose --dry-run.'
    Assert-True ($upgradeBatText -match '--stage') 'upgrade.bat does not expose --stage.'
    Assert-True ($upgradeBatText -notmatch 'PrepareFormal|InvalidateFormal|ValidateFormalApply|ApplyFormal|RecoverFormal|PreflightFormal|RepairMixedIsolated') 'upgrade.bat exposes an internal/formal upgrade mode.'
}

Invoke-GateCheck 'prepare smoke selector contract' {
    $prepareSmokeText = Get-Content -LiteralPath (Get-RepoPath 'tests\upgrade_formal_prepare_smoke.ps1') -Raw -Encoding UTF8
    foreach ($requiredText in @(
        '[string[]]$Group',
        '[string[]]$Case',
        'function Test-SmokeGroup',
        'function Invoke-SmokeGroup',
        'function Test-SmokeCase',
        'function Invoke-SmokeCase',
        'success-and-rerun',
        'failure-injection',
        'reentry-cleanup',
        'formal-boundary'
    )) {
        Assert-True ($prepareSmokeText.Contains($requiredText)) "prepare smoke selector contract missing: $requiredText"
    }
}

Invoke-GateCheck 'preflight helper contract' {
    Invoke-ExternalProcess -FileName 'powershell.exe' -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + (Get-RepoPath 'tests\upgrade_formal_preflight_contract.ps1') + '"') -TimeoutSeconds 30
}

if ($SkipPython) {
    Write-GateLine -Status 'SKIP' -Name 'Python unittest discovery' -Detail 'requested_by=-SkipPython'
}
else {
    Invoke-GateCheck 'Python unittest discovery' {
        Push-Location $RepoRoot
        try {
            & python -m unittest discover -s tests -p 'test_*.py' -v
            Assert-True ($LASTEXITCODE -eq 0) "python unittest failed exit=$LASTEXITCODE"
        }
        finally {
            Pop-Location
        }
    }
}

if ($SkipTempIntegration) {
    Write-GateLine -Status 'SKIP' -Name 'TEMP isolated upgrade rehearsal' -Detail 'requested_by=-SkipTempIntegration'
}
else {
    Invoke-GateCheck 'TEMP isolated upgrade rehearsal' {
        Invoke-ExternalProcess -FileName 'powershell.exe' -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + (Get-RepoPath 'tests\upgrade_isolated_smoke.ps1') + '"') -TimeoutSeconds $TempIntegrationTimeoutSeconds
        Assert-NoTempResidue
    }
    Invoke-GateCheck 'TEMP preflight path-boundary representative' {
        Invoke-ExternalProcess -FileName 'powershell.exe' -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + (Get-RepoPath 'tests\upgrade_formal_preflight_smoke.ps1') + '" -Group path-boundary -Case outside-temp-boundary -CaseTimeoutSeconds 30') -TimeoutSeconds 45
        Assert-NoTempResidue
    }
    Invoke-GateCheck 'TEMP preflight exact mixed positive' {
        Invoke-ExternalProcess -FileName 'powershell.exe' -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + (Get-RepoPath 'tests\upgrade_formal_preflight_smoke.ps1') + '" -Group source-target -Case exact-mixed -CaseTimeoutSeconds 30') -TimeoutSeconds 45
        Assert-NoTempResidue
    }
    Invoke-GateCheck 'TEMP preflight exact mixed near-miss negative' {
        Invoke-ExternalProcess -FileName 'powershell.exe' -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + (Get-RepoPath 'tests\upgrade_formal_preflight_smoke.ps1') + '" -Group source-target -Case exact-mixed-adapter-near-miss -CaseTimeoutSeconds 30') -TimeoutSeconds 45
        Assert-NoTempResidue
    }
    Invoke-GateCheck 'TEMP preflight exact mixed tray target-adjacent negative' {
        Invoke-ExternalProcess -FileName 'powershell.exe' -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + (Get-RepoPath 'tests\upgrade_formal_preflight_smoke.ps1') + '" -Group source-target -Case exact-mixed-tray-target-near-miss -CaseTimeoutSeconds 30') -TimeoutSeconds 45
        Assert-NoTempResidue
    }
}

Invoke-GateCheck 'formal basis live-origin and real-merge negatives' {
    Invoke-ExternalProcess -FileName 'powershell.exe' -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + (Get-RepoPath 'tests\upgrade_formal_prepare_smoke.ps1') + '" -Group basis-only') -TimeoutSeconds 30
}

Write-Output 'upgrade quick gate: NOT_RUN name=heavy matrix detail=prepare full failure-injection/reentry, preflight full fixture matrix except helper contract/path-boundary/exact-mixed representatives, formal apply full matrix, mixed repair full matrix, isolated apply full matrix'
Write-Output 'upgrade quick gate: NOT_RUN name=formal read-only detail=live PreflightFormal, live ValidateFormalApply, live PrepareFormal/ApplyFormal, transaction cleanup, formal runtime sync'

if ($script:Failed) {
    Write-Output 'upgrade quick gate: FAIL'
    exit 1
}

Write-Output 'upgrade quick gate: PASS'
exit 0
