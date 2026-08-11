## 0. Document Purpose 文件宗旨

本文件定義：

> **Laplace Sentry 系統的版本編碼規範、升級流程、相容性原則與演進治理制度**

目的為：

* 確保版本可辨識性
* 防止升級破壞舊資料
* 降低技術債累積速度
* 提供可追溯的演進歷史
* 建立穩定的長期維護模式

本文件屬於：

> **演進治理憲章（Evolution Governance Constitution）**

---

# 1. Versioning Philosophy 版本治理哲學

---

### 原則一：版本即契約

版本號代表系統對外行為的穩定程度。

### 原則二：相容性優先

升級不得破壞既有資料與操作流程。

### 原則三：可追溯性

所有版本變更必須可被追蹤與回溯。

### 原則四：演進不可跳躍

版本升級必須依序遞進，不得跨級跳版。

---

# 2. Semantic Versioning Model 語意化版本模型

---

## 2.1 標準格式

```text id="xj7qpl"
MAJOR.MINOR.PATCH
```

範例：

```text id="x0cqlm"
2.4.13
```

---

## 2.2 各欄位語意

| 層級    | 名稱  | 升級條件           |
| ----- | --- | -------------- |
| MAJOR | 主版本 | 架構重大變更 / 不相容變更 |
| MINOR | 次版本 | 新功能新增 / 向下相容   |
| PATCH | 修補版 | 錯誤修正 / 穩定性提升   |

---

## 2.3 升級範例說明

| 升級類型 | 舊版 → 新版       |
| ---- | ------------- |
| 修補錯誤 | 2.4.1 → 2.4.2 |
| 新功能  | 2.4.2 → 2.5.0 |
| 架構重構 | 2.5.0 → 3.0.0 |

---

# 3. Compatibility Governance 相容性治理原則

---

## 3.1 向下相容性（Backward Compatibility）

✔ 舊版資料必須可被新版解析
✔ 舊版 API 呼叫方式必須仍可使用
✔ 舊版設定檔不得失效

---

## 3.2 向上相容性（Forward Compatibility）

✔ 新版欄位應可被舊版忽略
✔ JSON Schema 允許新增非必要欄位

---

## 3.3 禁止行為

✘ 任意刪除既有欄位
✘ 任意修改資料型別
✘ 任意更改 CLI 指令語意
✘ 任意更改 API 參數順序

---

# 4. Schema Evolution Policy 資料結構演進政策

---

## 4.1 可接受變更

| 類型     | 是否允許 |
| ------ | ---- |
| 新增欄位   | ✔    |
| 新增選填參數 | ✔    |
| 擴充列舉值  | ✔    |

---

## 4.2 禁止變更

| 類型     | 原因      |
| ------ | ------- |
| 刪除欄位   | 破壞舊資料   |
| 型別變更   | 導致解析錯誤  |
| 必填欄位新增 | 舊資料無法補齊 |

---

## 4.3 必要破壞性變更流程

若必須進行不相容變更：

1️⃣ 升級 MAJOR 版本
2️⃣ 提供 Migration Tool
3️⃣ 提供雙版本解析支援
4️⃣ 公布升級指南
5️⃣ 更新 Volume C 文件

---

# 5. API Lifecycle Governance API 生命週期治理

---

## 5.1 API 狀態分類

| 狀態           | 說明    |
| ------------ | ----- |
| Stable       | 正式支援  |
| Deprecated   | 即將廢棄  |
| Experimental | 測試中功能 |
| Removed      | 已移除   |

---

## 5.2 API 廢棄流程

```text id="j96a3v"
公告棄用
   ↓
保留 1 個 MINOR 版本
   ↓
標示 Deprecated
   ↓
下個 MAJOR 版本移除
```

---

# 6. Release Governance 發佈治理規範

---

## 6.1 發佈類型

| 類型            | 說明   |
| ------------- | ---- |
| Patch Release | 修補錯誤 |
| Minor Release | 新增功能 |
| Major Release | 架構升級 |

---

## 6.2 發佈必備項目

✔ 更新版本號
✔ 更新變更日誌
✔ 更新相容性聲明
✔ 更新治理文件

---

# 7. Migration Governance 升級遷移治理

---

## 7.1 升級策略

| 策略    | 說明       |
| ----- | -------- |
| 自動遷移  | 系統自動轉換   |
| 半自動遷移 | 使用者確認後轉換 |
| 手動遷移  | 提供工具與指南  |

---

## 7.2 資料遷移原則

✔ 不覆蓋原始資料
✔ 保留回滾點
✔ 提供驗證機制

---

# 8. Change Log Governance 變更紀錄治理

---

## 8.1 變更紀錄格式

```text id="f8f41m"
## [版本號] - YYYY-MM-DD
### Added
### Changed
### Fixed
### Deprecated
### Removed
```

---

# 9. Current Upgrade Governance 現役升級治理

## 9.1 現役升級治理模型

### 單一目標真相

正式升級的 target commit 只允許由正式準備 helper 的單一欄位宣告。其他主程序、測試與文件只能讀取或指向該來源，不得各自複製一份動態版本值。

### Basis 與 checkpoint gate

正式準備前必須核對指定分支、遠端主線、staged 狀態（Git 暫存區）及既有修改範圍。staged 非空必須拒絕；dirty／untracked 僅接受正式 helper 明列的允許範圍，未列入允許範圍的 dirty 或 untracked 路徑必須拒絕。

checkpoint 只能是明示核准錨點，或符合核准 parent lineage 與精確 changed-path shape 的單一直接子版本。不得把任意後代、合併形狀、少檔、多檔或替換檔視為等價基準。

### Transaction journal 與 marker-last

正式準備與套用以 transaction journal 作為交易狀態與可恢復步驟的單一證據。套用前先封存原貌與來源證據；受控檔案全部寫入並通過檢查後，版本 marker 才能最後更新。

若中途失敗、證據不完整或重入狀態不明，流程必須停止並依 journal、preimage 與已完成步驟進入 rollback 或 recovery，不得靠重新複製整包掩蓋半輪狀態。

### 受保護資料與三副本邊界

升級流程必須明確區分：

1. 開發工作樹：原始碼、文件與測試的主要工程真相。
2. Windows Frontend 正式安裝副本：使用者實際啟動的前端及其本機設定。
3. WSL Backend 正式執行副本：後端程式、環境與受保護持久資料。

正式升級不得把工作樹修改直接視為 runtime 已更新，也不得用首次安裝器覆蓋既有副本。專案資料、設定、版本標記與其他受保護項目必須依 manifest、備份與驗證契約處理。

### 證據分級

| 證據層 | 能證明什麼 | 不能外推什麼 |
| --- | --- | --- |
| Quick gate | 日常語法、靜態契約、Python contract 與少量 TEMP 代表案例仍在 | 不代表完整 heavy matrix 或正式環境成立 |
| Heavy TEMP matrix | 在隔離目標中驗證失敗注入、重入、回復與邊界 | 不代表真實正式副本已檢查或套用 |
| Formal environment evidence | 經明確授權後，對正式環境進行唯讀預檢、準備、套用或復原所得證據 | 不得由較低層綠燈自動推定 |

任何一層通過，都只能支持該層實際執行的結論；release ready 必須另依正式發佈條件裁定。

### 正式授權邊界

公開升級入口只承接安全 dry-run 與 TEMP staging。正式 preflight、prepare、validation、apply 與 recovery 均屬授權制能力；存在內部實作或測試不等於已授權執行。

---

# 10. Constitutional Authority 憲章效力聲明

本文件為：

> **Laplace Sentry 版本與相容性治理之最高制度文件**

所有升級與版本變更
必須遵守本政策。


