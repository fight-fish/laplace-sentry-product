[CmdletBinding()]
param()
<#
.SYNOPSIS
在嚴格 TEMP 假交易上驗證 stale-target invalidation 契約。
.DESCRIPTION
Purpose: prove invalidation writes only the selected fake journal once and rejects unsafe reentry/tampering/boundaries.
Inputs: generated strict-TEMP transaction fixtures.
Outputs: PASS/FAIL only.
SSOT Output: process exit code.
Exit codes: 0 pass; 1 failure.
SKIP conditions: none.
FAIL conditions: state/evidence/hash/boundary/reentry contract failure or TEMP residue.
Order-sensitive checks: journal and manifest hashes are captured before each invocation.
Side effects: creates then removes only this run's verified system-TEMP children; never invokes live invalidation or accesses formal transaction roots.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$TempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
$SuiteRoot = Join-Path $TempRoot ('LaplaceSentryFormalInvalidateSmoke-' + [Guid]::NewGuid().ToString('N'))
function Get-NormalizedFullPath { param([string]$Path) [IO.Path]::GetFullPath($Path).TrimEnd('\','/') }
function Test-PathsEqual { param([string]$First,[string]$Second) (Get-NormalizedFullPath $First).Equals((Get-NormalizedFullPath $Second),[StringComparison]::OrdinalIgnoreCase) }
function Test-StrictPathInside { param([string]$Candidate,[string]$Container) $c=Get-NormalizedFullPath $Candidate; $r=(Get-NormalizedFullPath $Container).TrimEnd('\','/') + '\'; $c.StartsWith($r,[StringComparison]::OrdinalIgnoreCase) }
function Get-FileSha256 { param([string]$Path) (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash }
function Save-MixedRepairJournal { param([string]$JournalPath,$Journal) $Journal.updated_at_utc=[DateTime]::UtcNow.ToString('o'); $tmp="$JournalPath.tmp"; $Journal|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $tmp -Encoding UTF8; Move-Item -LiteralPath $tmp -Destination $JournalPath -Force }
function Get-OptionalProperty { param($Object,[string]$Name,$Default=$null) if($null -ne $Object.PSObject.Properties[$Name]){$Object.$Name}else{$Default} }
. (Join-Path $RepoRoot 'scripts\upgrade_formal_prepare.ps1')
. (Join-Path $RepoRoot 'scripts\upgrade_formal_apply.ps1')
. (Join-Path $RepoRoot 'scripts\upgrade_formal_invalidate.ps1')
function Assert-True { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw "[ASSERT_FAIL] $Message" } }
function Assert-Throws { param([scriptblock]$Action,[string]$Tag) $caught=$null;try{&$Action}catch{$caught=$_}; Assert-True ($null -ne $caught -and $caught.Exception.Message -match $Tag) "expected $Tag, got $($caught.Exception.Message)" }
function Remove-OwnTree { param([string]$Path) if ((Test-Path -LiteralPath $Path) -and (Test-StrictPathInside -Candidate $Path -Container $TempRoot)) { Remove-Item -LiteralPath $Path -Recurse -Force } }
function New-Case {
 # AgeMinutes 同時決定 transaction_id 時間戳與 created_at_utc，兩者必須一致才能通過時間身分校驗。
 # CreatedOverride 用來刻意製造兩者不一致或無法解析的負向案例。
 param([string]$Name,[string]$Result='prepared',[switch]$RuledTarget,[switch]$RootMismatch,[switch]$TamperManifest,[double]$AgeMinutes=0,[string]$CreatedOverride,[switch]$OmitCreated)
 $created=[DateTime]::UtcNow.AddMinutes(-$AgeMinutes)
 $root=Join-Path $SuiteRoot $Name; $tx=Join-Path $root ($created.ToString('yyyyMMddTHHmmssfffffffZ') + '-' + [Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $tx -Force | Out-Null; $refs=[ordered]@{}
 foreach($n in @('source','preimage','package')) { $path=Join-Path $tx "$n-manifest.json"; [pscustomobject]@{schema=$FormalPrepareSchema;manifest_type=$n;manifest_id="$n-id";records=@()}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $path -Encoding UTF8; $refs[$n]=[pscustomobject]@{path=$path;sha256=(Get-FileSha256 $path);id="$n-id"} }
 if($TamperManifest){ Add-Content -LiteralPath $refs.source.path -Value 'tamper' }
 $id=Split-Path -Leaf $tx
 $journal=[ordered]@{schema=$FormalPrepareSchema;mode='PrepareFormal';state='prepared_pending_apply';result=$Result;transaction_id=$id;transaction_root=if($RootMismatch){Join-Path $root 'wrong'}else{$tx};transaction_parent=$root;target_commit=if($RuledTarget){$FormalUpgradeTargetCommit}else{'971ba498d613c2bb20d46e14855cc0b0a326602a'};manifests=[pscustomobject]$refs;formal_target_write_count=0;fixture_mode=$false;events=@('prepared');updated_at_utc=[DateTime]::UtcNow.ToString('o')}
 if(-not $OmitCreated){ $journal['created_at_utc']=if($PSBoundParameters.ContainsKey('CreatedOverride')){$CreatedOverride}else{$created.ToString('o')} }
 [pscustomobject]$journal|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $tx 'transaction-journal.json') -Encoding UTF8
 return [pscustomobject]@{Root=$root;Transaction=$tx;Journal=(Join-Path $tx 'transaction-journal.json')}
}
function Assert-ZeroWrite {
 # 拒絕路徑必須完全不動 journal 與 evidence，否則等於在失敗時留下半套狀態。
 param($Case,[scriptblock]$Action,[string]$Tag,[string]$Label)
 $jh=Get-FileSha256 $Case.Journal; $sh=Get-FileSha256 (Join-Path $Case.Transaction 'source-manifest.json')
 Assert-Throws $Action $Tag
 Assert-True ((Get-FileSha256 $Case.Journal) -eq $jh -and (Get-FileSha256 (Join-Path $Case.Transaction 'source-manifest.json')) -eq $sh) "$Label rejection rewrote journal or manifest."
}
function Get-Inputs { param($Case) [pscustomobject]@{Mode='InvalidateFormalInternal';TransactionRoot=$Case.Transaction;IsolationRoot=$Case.Root;PreflightObservationPath=$null;FrontendTarget=(Join-Path $Case.Root 'fake-frontend');BackendTarget=(Join-Path $Case.Root 'fake-backend')} }
try {
 New-Item -ItemType Directory -Path $SuiteRoot -Force | Out-Null
 $success=New-Case 'success'; $journalHash=Get-FileSha256 $success.Journal; $sourceHash=Get-FileSha256 (Join-Path $success.Transaction 'source-manifest.json'); $result=Invoke-FormalInvalidateInternalMode -Inputs (Get-Inputs $success); $after=Get-Content $success.Journal -Raw -Encoding UTF8|ConvertFrom-Json
 Assert-True ($result.result -eq 'invalidated' -and $after.state -eq 'invalidated' -and [int]$after.formal_target_write_count -eq 0) 'success did not create zero-write invalidated terminal.'
 Assert-True ($after.invalidation.reason_code -eq 'stale_target_commit' -and $after.invalidation.prior_state -eq 'prepared_pending_apply' -and $after.invalidation.prior_result -eq 'prepared' -and $after.invalidation.journal_sha256_before -eq $journalHash -and $after.invalidation.manifest_sha256.source -eq $sourceHash) 'success evidence is incomplete or inconsistent.'
 $evidenceAfter=Get-FileSha256 (Join-Path $success.Transaction 'source-manifest.json'); Assert-True ($evidenceAfter -eq $sourceHash) 'invalidation rewrote evidence.'
 $journalAfter=Get-FileSha256 $success.Journal; Assert-Throws { Invoke-FormalInvalidateInternalMode -Inputs (Get-Inputs $success) } 'UPGRADE_INVALIDATE_TRANSACTION_FAIL'; Assert-True ((Get-FileSha256 $success.Journal) -eq $journalAfter) 'reentry rewrote invalidated journal.'
 $wrongResult=New-Case 'wrong-result' -Result 'prepared_pending_apply'; $wrongJournalHash=Get-FileSha256 $wrongResult.Journal; $wrongSourceHash=Get-FileSha256 (Join-Path $wrongResult.Transaction 'source-manifest.json'); Assert-Throws { Invoke-FormalInvalidateInternalMode -Inputs (Get-Inputs $wrongResult) } 'UPGRADE_INVALIDATE_TRANSACTION_FAIL'; Assert-True ((Get-FileSha256 $wrongResult.Journal) -eq $wrongJournalHash -and (Get-FileSha256 (Join-Path $wrongResult.Transaction 'source-manifest.json')) -eq $wrongSourceHash) 'wrong result rejection rewrote journal or manifest.'
 # 驗收 1：同 target 但仍在窗口內，必須拒絕且零寫入——這是 30 分鐘上限不被繞過的核心防線。
 $fresh=New-Case 'same-target-fresh' -RuledTarget
 Assert-ZeroWrite $fresh { Invoke-FormalInvalidateInternalMode -Inputs (Get-Inputs $fresh) } 'UPGRADE_INVALIDATE_TARGET_MATCH' 'fresh same-target'
 $freshEdge=New-Case 'same-target-edge' -RuledTarget -AgeMinutes ($FormalApplyMaximumAgeMinutes - 1)
 Assert-ZeroWrite $freshEdge { Invoke-FormalInvalidateInternalMode -Inputs (Get-Inputs $freshEdge) } 'UPGRADE_INVALIDATE_TARGET_MATCH' 'inside-window same-target'
 # 驗收 2：同 target 且確實逾時，允許一次 expired_transaction 失效並留下可信 age 證據。
 $expired=New-Case 'same-target-expired' -RuledTarget -AgeMinutes ($FormalApplyMaximumAgeMinutes + 5)
 $expiredHash=Get-FileSha256 $expired.Journal; $expiredSource=Get-FileSha256 (Join-Path $expired.Transaction 'source-manifest.json')
 $expiredResult=Invoke-FormalInvalidateInternalMode -Inputs (Get-Inputs $expired)
 $expiredAfter=Get-Content $expired.Journal -Raw -Encoding UTF8|ConvertFrom-Json
 Assert-True ($expiredResult.result -eq 'invalidated' -and $expiredAfter.state -eq 'invalidated' -and [int]$expiredAfter.formal_target_write_count -eq 0) 'expired same-target did not reach zero-write invalidated terminal.'
 Assert-True ($expiredAfter.invalidation.reason_code -eq 'expired_transaction' -and $expiredAfter.invalidation.observed_target_commit -eq $FormalUpgradeTargetCommit -and $expiredAfter.invalidation.ruled_target_commit -eq $FormalUpgradeTargetCommit) 'expired evidence target fields are wrong.'
 Assert-True ([int]$expiredAfter.invalidation.max_age_minutes -eq $FormalApplyMaximumAgeMinutes -and [double]$expiredAfter.invalidation.age_seconds -gt ($FormalApplyMaximumAgeMinutes * 60)) 'expired evidence does not prove the window was exceeded.'
 Assert-True ($expiredAfter.invalidation.prior_state -eq 'prepared_pending_apply' -and $expiredAfter.invalidation.prior_result -eq 'prepared' -and $expiredAfter.invalidation.journal_sha256_before -eq $expiredHash) 'expired evidence prior state or before-hash is wrong.'
 Assert-True ((Get-FileSha256 (Join-Path $expired.Transaction 'source-manifest.json')) -eq $expiredSource) 'expired invalidation rewrote evidence.'
 Assert-True (@($expiredAfter.events | Where-Object { $_ -eq 'invalidated:expired_transaction' }).Count -eq 1) 'expired invalidation did not append exactly one event.'
 $expiredTerminal=Get-FileSha256 $expired.Journal
 Assert-Throws { Invoke-FormalInvalidateInternalMode -Inputs (Get-Inputs $expired) } 'UPGRADE_INVALIDATE_TRANSACTION_FAIL'
 Assert-True ((Get-FileSha256 $expired.Journal) -eq $expiredTerminal) 'expired reentry rewrote invalidated journal.'
 # 驗收 4：時間欄位不可信者一律拒絕且零寫入，不得因「看起來夠舊」就放行。
 $noCreated=New-Case 'expired-missing-created' -RuledTarget -OmitCreated
 Assert-ZeroWrite $noCreated { Invoke-FormalInvalidateInternalMode -Inputs (Get-Inputs $noCreated) } 'UPGRADE_INVALIDATE_TRANSACTION_FAIL' 'missing created_at_utc'
 $malformed=New-Case 'expired-malformed-created' -RuledTarget -AgeMinutes 90 -CreatedOverride 'not-a-timestamp'
 Assert-ZeroWrite $malformed { Invoke-FormalInvalidateInternalMode -Inputs (Get-Inputs $malformed) } 'UPGRADE_APPLY_AGE_FAIL' 'malformed created_at_utc'
 $mismatch=New-Case 'expired-id-mismatch' -RuledTarget -AgeMinutes 90 -CreatedOverride ([DateTime]::UtcNow.AddMinutes(-31).ToString('o'))
 Assert-ZeroWrite $mismatch { Invoke-FormalInvalidateInternalMode -Inputs (Get-Inputs $mismatch) } 'UPGRADE_APPLY_AGE_FAIL' 'created_at_utc disagreeing with transaction id'
 $future=New-Case 'expired-future' -RuledTarget -AgeMinutes (-90)
 Assert-ZeroWrite $future { Invoke-FormalInvalidateInternalMode -Inputs (Get-Inputs $future) } 'UPGRADE_APPLY_AGE_FAIL' 'future-dated transaction'
 Assert-Throws { Invoke-FormalInvalidateInternalMode -Inputs (Get-Inputs (New-Case 'root-mismatch' -RootMismatch)) } 'UPGRADE_INVALIDATE_TRANSACTION_FAIL'
 Assert-Throws { Invoke-FormalInvalidateInternalMode -Inputs (Get-Inputs (New-Case 'manifest-tamper' -TamperManifest)) } 'UPGRADE_PREPARE_RECOVERY_REQUIRED'
 $boundaryCase=New-Case 'boundary'; Assert-Throws { Assert-FormalInvalidateInternalBoundary -Inputs (Get-Inputs $boundaryCase) } 'UPGRADE_INVALIDATE_BOUNDARY_FAIL'
 $upgradeBat=Get-Content (Join-Path $RepoRoot 'upgrade.bat') -Raw -Encoding UTF8; Assert-True ($upgradeBat -notmatch 'InvalidateFormal') 'upgrade.bat exposes internal invalidation.'
 Remove-OwnTree $SuiteRoot; Assert-True (-not (Test-Path -LiteralPath $SuiteRoot)) 'TEMP residue remains.'; Write-Output 'upgrade formal invalidate smoke: PASS'; exit 0
} catch { [Console]::Error.WriteLine("upgrade formal invalidate smoke: FAIL: $($_.Exception.Message)"); try { Remove-OwnTree $SuiteRoot } catch {}; exit 1 }
