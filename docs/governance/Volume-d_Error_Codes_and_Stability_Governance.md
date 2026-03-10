
## 0. Document Purpose 文件宗旨

本文件定義：

> **Laplace Sentry 全系統錯誤碼體系、錯誤分級標準、穩定性設計原則與可恢復性機制**

目的為：

* 建立統一錯誤語意
* 提升除錯效率
* 降低不可預期故障
* 強化系統韌性（Resilience）
* 防止靜默失敗（Silent Failure）

本文件屬於：

> **穩定性治理憲章（Stability Constitutional Document）**

---

# 1. Stability Governance Principles 穩定性治理原則

---

### 原則一：Fail Fast

系統遇到不可恢復錯誤時，必須立即中止流程，避免錯誤擴散。

---

### 原則二：Observable Failure

所有錯誤必須可被觀測與診斷，不得靜默吞錯。

---

### 原則三：Recoverable State

系統錯誤後必須能恢復至安全狀態。

---

### 原則四：Atomic Safety

關鍵寫入流程必須具備原子性，避免部分成功狀態。

---

### 原則五：Controlled Degradation

系統在局部失效時應降級運作，而非全面崩潰。

---

# 2. Error Classification Model 錯誤分類模型

---

## 2.1 錯誤層級定義

| 等級      | 類型                | 說明    | 系統反應    |
| ------- | ----------------- | ----- | ------- |
| Level 0 | Info              | 資訊提示  | 繼續運行    |
| Level 1 | Warning           | 可恢復異常 | 記錄並繼續   |
| Level 2 | Recoverable Error | 需修正異常 | 自動恢復後繼續 |
| Level 3 | Critical Error    | 嚴重錯誤  | 中止當前任務  |
| Level 4 | Fatal Error       | 致命錯誤  | 終止系統    |

---

## 2.2 錯誤來源分類

| 類型                 | 範圍             |
| ------------------ | -------------- |
| I/O Errors         | 檔案讀寫失敗         |
| Data Errors        | JSON 損壞 / 格式錯誤 |
| Logic Errors       | 工作流異常          |
| Environment Errors | Python / 依賴錯誤  |
| Permission Errors  | 權限不足           |
| Runtime Errors     | 執行期例外          |

---

# 3. Exit Code Governance CLI 錯誤碼治理

---

## 3.1 標準 Exit Code 定義

| Code | 類型               | 說明     |
| ---- | ---------------- | ------ |
| 0    | SUCCESS          | 任務成功   |
| 1    | USAGE_ERROR      | 指令參數錯誤 |
| 2    | ENV_ERROR        | 環境異常   |
| 3    | WORKFLOW_ERROR   | 工作流失敗  |
| 4    | IO_ERROR         | 檔案存取失敗 |
| 5    | DATA_ERROR       | 資料損壞   |
| 6    | PERMISSION_ERROR | 權限不足   |
| 7    | INTERRUPTED      | 任務中斷   |
| 9    | UNKNOWN_ERROR    | 未知錯誤   |

---

## 3.2 Exit Code 使用原則

* 不得混用語意
* 不得使用隨機數值
* CLI 必須明確回傳
* UI 層不得吞沒 Exit Code

---

# 4. Logging Governance 日誌治理規範

---

## 4.1 日誌層級標準

| 層級       | 用途     |
| -------- | ------ |
| INFO     | 正常流程記錄 |
| WARN     | 非致命異常  |
| ERROR    | 任務失敗   |
| CRITICAL | 系統級故障  |

---

## 4.2 日誌格式標準

```text
[Timestamp] [Level] [Module] Message
```

範例：

```text
[2026-03-10 14:32:10] [ERROR] [IO_GATEWAY] JSON decode failed
```

---

# 5. I/O Stability Mechanisms I/O 穩定性機制

---

## 5.1 強制鎖定機制

所有寫入必須先取得檔案鎖。

## 5.2 原子替換機制

必須透過 temp file + replace 完成。

## 5.3 備份輪替機制

保留最近 N 份備份。

## 5.4 自癒復原機制

資料損壞時自動從備份復原。

---

# 6. Runtime Protection 應用層保護機制

---

## 6.1 哨兵節流保護

防止爆量更新導致系統過載。

## 6.2 黑名單保護

避免監控輸出文件造成循環觸發。

## 6.3 快照比對保護

僅在有效變更時觸發更新。

---

# 7. Recovery Governance 復原治理機制

---

## 7.1 自動復原

I/O 損壞 → 備份復原

## 7.2 降級運作

部分模組失效 → 核心功能維持

## 7.3 手動復原

透過備份回滾專案資料

---

# 8. Anti-Silent-Failure Policy 禁止靜默失敗政策

所有異常必須：

* 顯示於 STDERR
* 記錄於日誌
* 回傳 Exit Code
* 可被 UI 捕捉

---

# 9. Constitutional Authority 憲章效力聲明

本文件為：

> **Laplace Sentry 全系統穩定性與錯誤治理最高制度文件**

所有錯誤處理與恢復機制
必須符合本文件之規範。


