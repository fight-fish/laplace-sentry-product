以下為完整中文翻譯：

---

# 測試（Tests）

此目錄包含目前專案（Repository）的各項測試入口。

它刻意保持精簡且以實際操作為主，目的在於讓人一眼就知道：

* 每個指令是在測試哪一層功能。
* 哪些層級**沒有**因為快速測試通過（Fast Green）而被涵蓋。

---

# 快速檢查（Quick Gate）

如果你要回報：

> 「此專案已完成快速的升級安全檢查」

請先執行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run_upgrade_quick_gate.ps1
```

---

快速檢查會執行下列項目：

| 層級                  | 執行內容                                                                                        | 主要保護的風險                                                                                         |
| ------------------- | ------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Python 合約測試         | `python -m unittest discover -s tests -p 'test_*.py' -v`                                    | 確保目前 Python Tree Query API 不會因修改而退化。                                                            |
| PowerShell 語法解析     | 檢查 `scripts\upgrade*.ps1` 是否可正常解析，並執行升級 Smoke Test                                          | 避免升級腳本因語法錯誤而被默默跳過。                                                                              |
| 靜態升級契約檢查            | 檢查正式 Target Commit 是否只有單一來源、公開 `upgrade.bat` 是否正確分派、Prepare Smoke Selector 是否存在             | 防止 Target Commit 被複製、正式模式入口消失或 Selector 消失所造成的假綠燈（False Green）。                                  |
| Preflight Helper 契約 | `tests\upgrade_formal_preflight_contract.ps1`                                               | 在不執行大型測試矩陣的情況下，確認 PreflightFormal 的 Selector／Tag 對 Source、Target、Runtime、受保護資料及非同步子程序輸出的連線仍然存在。 |
| TEMP 整合測試           | `tests\upgrade_isolated_smoke.ps1`                                                          | 驗證公開的 `upgrade.bat --stage` 能正確進入嚴格 TEMP 演練流程，並保護正式資料。                                          |
| TEMP Preflight 代表案例 | `tests\upgrade_formal_preflight_smoke.ps1 -Group path-boundary -Case outside-temp-boundary` | 驗證 Preflight 能拒絕 Repository 或 TEMP 外部的測試路徑，且不會碰觸正式資料。                                           |

---

Python Tree Query 合約測試使用 `tests\_tree_query_contract_bootstrap.py` 集中處理測試入口與 backend import root；單支測試不應各自直接修改 `sys.path` 來接 backend。

---

快速檢查**並不代表升級功能已完全安全**。

它的目的只是證明：

> PowerShell 升級防護並沒有完全缺席，而且已經納入平時交接流程的快速檢查中，同時仍能保持足夠快速、可經常執行。

---

## 升級基準與版本錨點門檻

正式準備測試會先核對目前程式庫基準，至少包含：

- 不接受 staged changes（Git 暫存區非空）。
- 不接受錯誤分支或與正式契約不一致的遠端主線。
- 只允許正式 helper 明列的既有修改；未列入允許範圍的 dirty 或 untracked 路徑一律拒絕。
- 版本錨點必須是明示核准的錨點，或符合明示 parent lineage 與精確 changed-path shape 的單一直接子版本。
- 少檔、多檔、替換檔、錯誤父版本、合併形狀或更深後代均不得靠名稱相似而通過。

這些門檻保護的是測試輸入基準，不代表正式環境已被檢查或可以套用升級。

---

如果目前無法使用 Python，但仍希望檢查 PowerShell 升級防護，可以執行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run_upgrade_quick_gate.ps1 -SkipPython
```

---

如果刻意略過 TEMP 整合測試，可以執行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run_upgrade_quick_gate.ps1 -SkipTempIntegration
```

---

無論使用哪一種 Skip 參數，都必須在報告中明確說明。

**被略過的測試層不能視為已通過。**

---

# 升級測試層級（Upgrade Test Layers）

| 層級                         | 入口                                         | 預期耗時            | 是否碰觸正式資料                      | 是否屬於每輪預設檢查                                                             | 若未執行，報告應寫                                                                     |
| -------------------------- | ------------------------------------------ | --------------- | ----------------------------- | ---------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| 快速檢查                       | `tests\run_upgrade_quick_gate.ps1`         | 數秒～約一分鐘         | 不會；預設只用 TEMP                  | 是                                                                      | `本輪未執行 Quick Gate，因此未驗證 Upgrade PowerShell 防護。`                               |
| Python 單元／契約測試             | `python -m unittest discover...`           | 數秒              | 不會                            | 已包含於 Quick Gate                                                        | `未執行 Python Contract Tests。`                                                  |
| TEMP Prepare 整合測試          | `tests\upgrade_formal_prepare_smoke.ps1`   | 每組／每案例不同；完整測試較慢 | 僅讀取規格允許的 Metadata；測試資料皆在 TEMP | 否（Quick Gate 只驗 Selector／Contract）                                     | `未執行 PrepareFormal TEMP 整合，因此 Prepare Transaction／Manifest／Reentry 風險本輪未驗證。`  |
| TEMP Formal Apply 整合測試     | `tests\upgrade_formal_apply_smoke.ps1`     | 很耗時             | 不會；僅使用 TEMP                   | 否                                                                      | `未執行 Formal Apply TEMP Matrix，因此 Rollback 與 Marker 等高覆蓋測試本輪未驗證。`              |
| TEMP Preflight 整合測試        | `tests\upgrade_formal_preflight_smoke.ps1` | 每案例／每組不同；完整矩陣較慢 | 不會；僅使用 TEMP 假目標               | Quick Gate 只包含 Helper Contract 與 `path-boundary/outside-temp-boundary` | `未執行完整 PreflightFormal Fixture Matrix，本輪僅驗證 Helper Contract 與指定 Selector 案例。` |
| TEMP Mixed Repair 整合測試     | `tests\upgrade_mixed_repair_smoke.ps1`     | 很耗時             | 不會；僅使用 TEMP                   | 否                                                                      | `未執行 Mixed Repair TEMP Matrix，因此混合版本 Rollback 覆蓋本輪未驗證。`                       |
| TEMP Isolated Apply Matrix | `tests\upgrade_isolated_apply_smoke.ps1`   | 很耗時             | 不會；僅使用 TEMP                   | 否                                                                      | `未執行 Isolated Apply Rollback Matrix。`                                         |
| 正式環境唯讀人工檢查                 | 經授權後，僅執行唯讀 Preflight／Transaction 驗證        | 人工操作，依環境而定      | 僅唯讀且須明確授權                     | 否                                                                      | `未執行正式環境唯讀檢查，因此本輪未對正式環境做任何宣稱。`                                                |

---

# 保留中的淘汰候選（Retire Candidates）

以下內容**目前只是候選**，**不得刪除或重寫**，除非：

* 有新的正式裁決（Formal Ruling）。
* 並有證據證明新的防護方式能涵蓋相同風險。

包括：

* Prepare、Apply、Mixed Repair、Isolated Apply 中大量重疊的 Path Overlap／Reparse Boundary 測試矩陣。
* 大型 Smoke Test 中的靜態 Regex 契約檢查。
* 如果未來 `ApplyIsolated` 不再屬於現行安全需求，可考慮淘汰 `upgrade_isolated_apply_smoke.ps1` 中大量重複的部分。
* `upgrade_formal_preflight_smoke.ps1` 目前整支檔案未切分的完整使用方式。

---

# 報告規則（Reporting Rule）

若 Quick Gate 全部通過（Green），**只能代表：**

> Python Contract 測試、PowerShell Parser／Static Contract、Preflight Helper Contract、一個嚴格 TEMP 的公開 Stage 演練，以及 Preflight `path-boundary/outside-temp-boundary` 代表案例皆已通過。

**並不代表：**

* 完整的 Prepare／Apply／Preflight／Mixed Repair 大型測試矩陣都已通過。
* 正式環境（Formal Runtime）的資料已被檢查。
* 已實際執行 `PrepareFormal`、`ValidateFormalApply` 或 `ApplyFormal`。
* 已證明 Transaction Cleanup、Runtime 同步、Git 狀態或產品已達可發布（Release Ready）狀態。

因此 Quick Gate 全綠不得外推為 heavy matrix、formal read-only、live apply 或 release ready 已成立；每一層都必須有自己的實際執行證據。
