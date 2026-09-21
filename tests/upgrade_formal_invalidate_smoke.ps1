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
function Assert-Throws { param([scriptblock]$Action,[string]$Tag) $caught=$null;try{&$Action|Out-Null}catch{$caught=$_}; $msg=if($null -eq $caught){'<no exception>'}elseif($null -ne $caught.Exception){[string]$caught.Exception.Message}else{[string]$caught}; Assert-True ($null -ne $caught -and $msg -match $Tag) "expected $Tag, got $msg" }
function Remove-OwnTree { param([string]$Path) if ((Test-Path -LiteralPath $Path) -and (Test-StrictPathInside -Candidate $Path -Container $TempRoot)) { Remove-Item -LiteralPath $Path -Recurse -Force } }
function New-Case {
 # AgeMinutes 同時決定 transaction_id 時間戳與 created_at_utc，兩者必須一致才能通過時間身分校驗。
 # CreatedOverride 用來刻意製造兩者不一致或無法解析的負向案例。
 param([string]$Name,[string]$Result='prepared',[switch]$RuledTarget,[switch]$RootMismatch,[switch]$TamperManifest,[double]$AgeMinutes=0,[double]$AgeSeconds,[string]$CreatedOverride,[switch]$OmitCreated)
 # AgeSeconds 用於捨入邊界案例，需要秒以下精度；未指定時沿用 AgeMinutes。
 $created=if($PSBoundParameters.ContainsKey('AgeSeconds')){[DateTime]::UtcNow.AddSeconds(-$AgeSeconds)}else{[DateTime]::UtcNow.AddMinutes(-$AgeMinutes)}
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
 # 捨入邊界：raw age 落在 (1800.000, 1800.0005] 時，三位小數證據會回落至 1800.000。
 # 判定必須使用同一個正規化值，否則會先寫入 invalidated 再自驗失敗，留下半套交易。
 # 真實時鐘無法穩定停在毫秒以下的窗口（實測 fixture 建立到判定之間即前進數十毫秒），
 # 故以直接呼叫正規化 helper 驗證契約，再用大偏移案例驗證端到端流程。
 $limitSeconds=$FormalApplyMaximumAgeMinutes * 60
 foreach($raw in @(1800.0, 1800.0001, 1800.0004, 1800.00049, 1800.0005)){
   $norm=Get-FormalInvalidateEvidenceAge -RawAgeSeconds $raw
   Assert-True ($norm -le $limitSeconds) "normalised age for raw $raw must not exceed the window (got $norm)."
 }
 foreach($raw in @(1800.001, 1800.01, 1801.0)){
   $norm=Get-FormalInvalidateEvidenceAge -RawAgeSeconds $raw
   Assert-True ($norm -gt $limitSeconds) "normalised age for raw $raw must exceed the window (got $norm)."
   Assert-True ($norm -eq [Math]::Round($norm,3)) "normalised age for raw $raw is not three-decimal."
 }
 # 正規化後仍明確大於門檻者必須可失效，且落檔值即判定所用的正規化值。
 $justOver=New-Case 'round-boundary-over' -RuledTarget -AgeSeconds ($limitSeconds + 2)
 $justOverResult=Invoke-FormalInvalidateInternalMode -Inputs (Get-Inputs $justOver)
 $justOverAfter=Get-Content $justOver.Journal -Raw -Encoding UTF8|ConvertFrom-Json
 Assert-True ($justOverResult.result -eq 'invalidated' -and $justOverAfter.state -eq 'invalidated') 'just-over boundary did not invalidate.'
 $joAge=[double]$justOverAfter.invalidation.age_seconds
 Assert-True ($joAge -gt $limitSeconds) 'just-over evidence age is not above the window.'
 Assert-True ($joAge -eq [Math]::Round($joAge,3)) 'landed age_seconds is not the normalised three-decimal value.'
 # 接線驗證：invalidator 必須真的經過正規化 helper，而非各自捨入。
 # 真實時鐘無法穩定落在 0.5 毫秒窗，故以「暫時攔截 helper」證明判定路徑確實呼叫它；
 # 若判定改回使用 raw age，攔截將不再生效、下方斷言即失敗。
 $script:NormaliseCallCount=0
 $realNormalise=(Get-Command Get-FormalInvalidateEvidenceAge).ScriptBlock
 function Get-FormalInvalidateEvidenceAge { param([Parameter(Mandatory=$true)][double]$RawAgeSeconds)
   $script:NormaliseCallCount++
   return [double][Math]::Round($RawAgeSeconds,3) }
 $wired=New-Case 'normalise-wired' -RuledTarget -AgeSeconds ($limitSeconds + 2)
 $wiredBefore=$script:NormaliseCallCount
 [void](Invoke-FormalInvalidateInternalMode -Inputs (Get-Inputs $wired))
 Assert-True ($script:NormaliseCallCount -gt $wiredBefore) 'invalidator did not route its age through the normalisation helper.'
 Set-Item -Path function:Get-FormalInvalidateEvidenceAge -Value $realNormalise
 Assert-True ((Get-FormalInvalidateEvidenceAge -RawAgeSeconds 1800.0004) -le $limitSeconds) 'helper restore failed.'
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
 # 直接時間契約：不經 Prepare／Apply fixture，故不受 production basis gate 影響，可在任意 HEAD 執行。
 # 覆蓋共用解析層與 apply 上限層的既有語義，確保本輪正規化未改動 Apply／Validate 判定。
 function New-AgeJournal { param([double]$AgeSeconds,[string]$CreatedOverride,[string]$IdOverride)
   $t=[DateTime]::UtcNow.AddSeconds(-$AgeSeconds)
   [pscustomobject]@{
     created_at_utc=$(if($PSBoundParameters.ContainsKey('CreatedOverride')){$CreatedOverride}else{$t.ToString('o')})
     transaction_id=$(if($PSBoundParameters.ContainsKey('IdOverride')){$IdOverride}else{$t.ToString('yyyyMMddTHHmmssfffffffZ')+'-'+('a'*32)})
   } }
 $limitSeconds=$FormalApplyMaximumAgeMinutes * 60
 # fresh：兩層都接受
 $freshJ=New-AgeJournal -AgeSeconds 5
 Assert-True ((Get-FormalTransactionAgeSeconds -Journal $freshJ) -ge 5) 'shared parser rejected a fresh journal.'
 Assert-True ((Get-FormalApplyTransactionAge -Journal $freshJ) -le $limitSeconds) 'apply age gate rejected a fresh journal.'
 # expired：共用層接受並回報真實 age，apply 層必須拒絕
 $expJ=New-AgeJournal -AgeSeconds ($limitSeconds + 600)
 Assert-True ((Get-FormalTransactionAgeSeconds -Journal $expJ) -gt $limitSeconds) 'shared parser did not report an expired age.'
 Assert-Throws { Get-FormalApplyTransactionAge -Journal $expJ } 'UPGRADE_APPLY_AGE_FAIL'
 # malformed created_at_utc：兩層都必須拒絕
 $malJ=New-AgeJournal -AgeSeconds 60 -CreatedOverride 'not-a-timestamp'
 Assert-Throws { Get-FormalTransactionAgeSeconds -Journal $malJ } 'UPGRADE_APPLY_AGE_FAIL'
 Assert-Throws { Get-FormalApplyTransactionAge -Journal $malJ } 'UPGRADE_APPLY_AGE_FAIL'
 # future-dated：共用層即拒絕，不得被視為 fresh
 $futJ=New-AgeJournal -AgeSeconds (-600)
 Assert-Throws { Get-FormalTransactionAgeSeconds -Journal $futJ } 'UPGRADE_APPLY_AGE_FAIL'
 Assert-Throws { Get-FormalApplyTransactionAge -Journal $futJ } 'UPGRADE_APPLY_AGE_FAIL'
 # identity mismatch：created_at_utc 與 transaction_id 時間戳不一致必須拒絕
 $mmJ=New-AgeJournal -AgeSeconds 60 -CreatedOverride ([DateTime]::UtcNow.AddSeconds(-3600).ToString('o'))
 Assert-Throws { Get-FormalTransactionAgeSeconds -Journal $mmJ } 'UPGRADE_APPLY_AGE_FAIL'
 # id shape 不合法必須拒絕
 $shapeJ=New-AgeJournal -AgeSeconds 60 -IdOverride 'not-a-transaction-id'
 Assert-Throws { Get-FormalTransactionAgeSeconds -Journal $shapeJ } 'UPGRADE_APPLY_AGE_FAIL'
 $upgradeBat=Get-Content (Join-Path $RepoRoot 'upgrade.bat') -Raw -Encoding UTF8; Assert-True ($upgradeBat -notmatch 'InvalidateFormal') 'upgrade.bat exposes internal invalidation.'
 Remove-OwnTree $SuiteRoot; Assert-True (-not (Test-Path -LiteralPath $SuiteRoot)) 'TEMP residue remains.'; Write-Output 'upgrade formal invalidate smoke: PASS'; exit 0
} catch { [Console]::Error.WriteLine("upgrade formal invalidate smoke: FAIL: $($_.Exception.Message)"); try { Remove-OwnTree $SuiteRoot } catch {}; exit 1 }
