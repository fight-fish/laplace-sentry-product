[CmdletBinding()]
param()

<#
.SYNOPSIS
Checks the fast static contract for formal preflight fixture coverage.

.DESCRIPTION
Purpose: keep quick gate aware of PreflightFormal source/target/runtime/protected contract wiring without running the heavy fixture matrix.
Inputs: scripts/upgrade.ps1 and tests/upgrade_formal_preflight_smoke.ps1 text.
Outputs: one PASS line or an assertion failure.
SSOT Output: process exit code; zero means the static preflight contract is still visibly wired.
Exit codes: 0 pass, 1 contract assertion failed.
Side effects: read-only; no TEMP fixture, formal runtime, transaction, process, Git, or product writes.
#>

# 這支腳本在做什麼：快速檢查 PreflightFormal 的 tag / selector / 責任映射仍存在，供 quick gate 常跑。
# 這支腳本不做什麼：不證明完整行為、不取代 upgrade_formal_preflight_smoke.ps1 的 heavy fixture matrix。
# 常改區塊：下方 contract pattern 清單。
# 不要亂動的區塊：本腳本只能讀檔與斷言，不可啟動 formal runtime 或建立 transaction。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$UpgradeScript = Join-Path $RepoRoot 'scripts\upgrade.ps1'
$PreflightSmoke = Join-Path $PSScriptRoot 'upgrade_formal_preflight_smoke.ps1'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-MatchText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )
    Assert-True ([regex]::IsMatch($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) $Message
}

try {
    Assert-True (Test-Path -LiteralPath $UpgradeScript -PathType Leaf) 'Missing scripts/upgrade.ps1.'
    Assert-True (Test-Path -LiteralPath $PreflightSmoke -PathType Leaf) 'Missing tests/upgrade_formal_preflight_smoke.ps1.'

    $upgradeText = Get-Content -LiteralPath $UpgradeScript -Raw -Encoding UTF8
    $smokeText = Get-Content -LiteralPath $PreflightSmoke -Raw -Encoding UTF8

    foreach ($caseName in @(
        'success',
        'source-dirty',
        'target-missing',
        'marker-missing',
        'marker-different',
        'marker-unknown',
        'marker-non-ancestor',
        'managed-drift',
        'delete-and-requirements-policy',
        'ui-active-lock-ambiguous',
        'owned-daemon-worker',
        'stale-registry-warning',
        'pid-reuse-unregistered-worker',
        'protected-missing-unreadable',
        'outside-temp-boundary'
    )) {
        Assert-True ($smokeText.Contains("'$caseName'")) "Preflight smoke selector no longer exposes case: $caseName"
    }

    foreach ($groupName in @('source-target', 'runtime-observation', 'protected-data', 'path-boundary')) {
        Assert-True ($smokeText.Contains("'$groupName'")) "Preflight smoke selector no longer exposes group: $groupName"
    }

    Assert-MatchText $upgradeText 'function\s+Invoke-FormalPreflightMode' 'PreflightFormal implementation entry is missing.'
    Assert-MatchText $upgradeText 'mode\s*=\s*''PreflightFormal''' 'PreflightFormal result mode contract is missing.'
    Assert-MatchText $upgradeText 'excluded\s*=\s*\[pscustomobject\]@\{\s*paper_watcher\s*=\s*\$true\s*\}' 'paper_watcher exclusion contract is missing.'

    Assert-MatchText $upgradeText 'source_dirty.*\[UPGRADE_SOURCE_DIRTY\]|\[UPGRADE_SOURCE_DIRTY\].*source_dirty' 'source_dirty no longer maps visibly to UPGRADE_SOURCE_DIRTY.'
    Assert-MatchText $upgradeText '\[UPGRADE_TARGET_FAIL\].*missing|missing.*\[UPGRADE_TARGET_FAIL\]' 'target missing contract no longer maps to UPGRADE_TARGET_FAIL.'
    Assert-MatchText $upgradeText '\[UPGRADE_VERSION_FAIL\].*marker|marker.*\[UPGRADE_VERSION_FAIL\]' 'version marker contract no longer maps to UPGRADE_VERSION_FAIL.'
    Assert-MatchText $upgradeText 'Get-FormalTargetCoherence.*\[UPGRADE_TARGET_DRIFT\]|\[UPGRADE_TARGET_DRIFT\].*Get-FormalTargetCoherence' 'target coherence drift contract is missing.'
    Assert-MatchText $upgradeText 'tracked_deletions.*\[UPGRADE_SOURCE_DELETE\]|\[UPGRADE_SOURCE_DELETE\].*tracked_deletions' 'tracked deletion fixture contract is missing.'
    Assert-MatchText $upgradeText 'requirements_changes.*\[UPGRADE_POLICY_FAIL\]|\[UPGRADE_POLICY_FAIL\].*requirements_changes' 'requirements policy fixture contract is missing.'

    Assert-MatchText $upgradeText 'function\s+Apply-PreflightProcessAssessment' 'runtime observation assessment helper is missing.'
    Assert-MatchText $upgradeText 'lock_exists.*\[UPGRADE_UI_ACTIVE\]|\[UPGRADE_UI_ACTIVE\].*lock_exists' 'UI lock contract no longer maps to UPGRADE_UI_ACTIVE.'
    Assert-MatchText $upgradeText '\[UPGRADE_RUNTIME_ACTIVE\]' 'owned daemon/worker contract no longer maps to UPGRADE_RUNTIME_ACTIVE.'
    Assert-MatchText $upgradeText '\[UPGRADE_REGISTRY_STALE\]' 'stale registry warning contract is missing.'
    Assert-MatchText $upgradeText '\[UPGRADE_RUNTIME_AMBIGUOUS\]' 'ambiguous runtime contract is missing.'

    Assert-MatchText $upgradeText 'protected_unreadable.*\[UPGRADE_PROTECTED_DATA_FAIL\]|\[UPGRADE_PROTECTED_DATA_FAIL\].*protected_unreadable' 'protected_unreadable no longer maps to UPGRADE_PROTECTED_DATA_FAIL.'
    Assert-MatchText $upgradeText 'Backend/data/projects\.json' 'required Backend/data/projects.json protected-data contract is missing.'

    Assert-MatchText $smokeText 'StandardOutput\.ReadToEndAsync\(\)' 'Preflight smoke child stdout is not drained asynchronously.'
    Assert-MatchText $smokeText 'StandardError\.ReadToEndAsync\(\)' 'Preflight smoke child stderr is not drained asynchronously.'

    Write-Output '[PASS] formal preflight helper contract preserved source/target/runtime/protected selector and tag wiring.'
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
