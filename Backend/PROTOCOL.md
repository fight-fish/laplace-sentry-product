# -----------------------------------------

# **PROTOCOL.md v2.0 — Laplace Sentry Backend Contract**

# -----------------------------------------

## 0. 範圍（Scope）

本協定僅適用於 **WSL 後端系統（Laplace Sentry Control Backend）**，負責：

* 專案管理
* 哨兵進程（sentry_worker）啟停
* 更新流程觸發
* 檔案樹生成與格式化（worker/engine/formatter）
* 安全 I/O（io_gateway）
* CLI 指令協定（main.py）

**UI（tray_app.py / The Eye / Dashboard）不屬於本協定範圍。**
UI 僅能透過 Adapter → WSL → `main.py` 與後端通訊。

---

# 1. 系統架構（Architecture）

後端模組由七個明確層級組成：

```
UI (Windows)
  ↓ Adapter（WSL 指令橋）
main.py（CLI 指令層）
  ↓
daemon 行為（由 main.py 與 sentry_worker.py 分拆實現）
  ↓
sentry_worker.py（檔案監控 + 快照 + 節流器）
  ↓
worker.py（更新流水線：engine + formatter）
  ↓
engine.py（樹生成）
formatter.py（格式化）
  ↓
io_gateway.py（atomic_write）
```

每層的邊界在後續章節中精確定義。

---

# 2. 模組職責（Module Responsibilities）

以下條列基於實際代碼逐行比對後的真實行為。

---

## 2.1 `main.py`（指令入口 / 後端 API 層）

### **允許（Allowed）**

* 接受 CLI 指令，包含：

  * `list_projects`
  * `add_project`
  * `delete_project`
  * `edit_project`
  * `add_target`
  * `remove_target`
  * `start_sentry`
  * `stop_sentry`
  * `manual_update`
  * `get_log`
* 調用：

  * `io_gateway` 寫入 `projects.json`
  * `worker.execute_update_workflow()` 執行更新流水線
* 啟動與終止哨兵進程（spawn / kill sentry_worker.py）
* 回傳 JSON 或純文字輸出

### **禁止（Forbidden）**

* ❌ 不做任何檔案監控行為
* ❌ 不解析節流邏輯（交由 sentry_worker）
* ❌ 不執行 engine / formatter（改由 worker）
* ❌ 不直接讀寫 output files（寫入由 io_gateway）
* ❌ 不讀取 `.sentry_status`（由 sentry_worker 寫入）

---

## 2.2 `sentry_worker.py`（真正哨兵進程）

### **允許（Allowed）**

* 建立初始快照（FileSnapshot）
* 使用 os.walk 快速掃描
* 監控檔案修改（modified / created / deleted）
* 執行 SmartThrottler（R1 / R3 / R4）
* 動態維護靜默清單
* 寫入 `.sentry_status` 於 `/tmp/<uuid>.sentry_status`
* 在事件通過節流器後，觸發：

```
trigger_update_cli(uuid)
→ main.py manual_update
→ worker → engine → formatter → io_gateway
```

### **禁止（Forbidden）**

* ❌ 不直接寫入 output files
* ❌ 不寫入 projects.json
* ❌ 不維持任何專案資訊（由 main.py 管理）
* ❌ 不管理 lifecycle（由 main.py 啟停）
* ❌ 不解析 ignore patterns（僅限 engine/worker 使用）

---

## 2.3 `worker.py`（更新流水線：engine + formatter）

### **允許（Allowed）**

* 執行完整的更新工作流程：

```
1. engine.generate_annotated_tree(project_path, old_content, ignore_patterns)
2. fake stdin/out 執行 formatter.main()
3. 將 formatter 的結果回傳 main.py
```

### 回傳格式：

```
(exit_code, output_str)

exit_code = 0 → 成功
exit_code = 3 → 內部運行錯誤
```

### **禁止（Forbidden）**

* ❌ 不做任何 I/O
* ❌ 不觸碰 output files
* ❌ 不操作 projects.json
* ❌ 不讀取 / 寫入 .sentry_status
* ❌ 不做檔案監控
* ❌ 不涉及節流器判斷

worker 是純運算層。

---

## 2.4 `engine.py`（樹生成）

### **允許（Allowed）**

* 遍歷專案目錄（受 ignore_patterns 約束）
* 產生 Annotated Tree（含節點屬性、深度控制）
* 用於 formatter 的中間層輸入

### **禁止（Forbidden）**

* ❌ 不做任何檔案寫入
* ❌ 不直接讀取 output_file
* ❌ 不處理 SmartThrottler
* ❌ 不啟動哨兵

engine 是純資料轉換層（stateless）。

---

## 2.5 `formatter.py`（格式化）

### **允許（Allowed）**

* 接受來自 engine 的輸入
* 根據策略（預設 obsidian）輸出格式化文字
* 對 worker 提供 CLI 友好的 main() 入口

### **禁止（Forbidden）**

* ❌ 不做任何 I/O
* ❌ 不解析專案設定
* ❌ 不與 daemon 互動

formatter 為 stateless 純函數層。

---

## 2.6 `io_gateway.py`（原子寫入 I/O）

### **允許（Allowed）**

* atomic_write with portalocker + tempfile
* safe_read_modify_write
* 唯一合法寫入：

  * `projects.json`
  * output files（由 main.py 指派）

### **禁止（Forbidden）**

* ❌ 不做邏輯判斷
* ❌ 不做節流器行為
* ❌ 不與 worker / engine 互動

---

## 2.7 `path.py`（跨平台路徑）

### **允許（Allowed）**

* Windows → WSL `/mnt/<drive>/<path>` 轉換
* WSL UNC 清理
* validate_path
* 提供 read/write CLI

### **禁止（Forbidden）**

* ❌ 不做任何業務邏輯
* ❌ 不觸碰 projects.json
* ❌ 不參與更新流程

---

# 3. 資料格式（Data Contracts）

---

## 3.1 `projects.json`（唯一後端真實來源）

格式：

```json
[
  {
    "uuid": "str",
    "name": "str",
    "path": "/abs/path",
    "output_file": ["/abs/path/file.md"],
    "target_files": ["/abs/path/file.md"],
    "status": "running" | "stopped" | "invalid_path" | "muting"
  }
]
```

### 管理規則

* 唯一可寫入者：`main.py` → `io_gateway`
* 必須使用 atomic_write
* UI 禁止直接讀取
* worker 禁止寫入
* sentry_worker 禁止寫入

---

## 3.2 `.sentry_status`（哨兵靜默狀態）

位置：

```
/tmp/<uuid>.sentry_status
```

格式：

```json
["/muted/path/a", "/muted/path/b"]
```

### 來源 / 權限

* 由 sentry_worker 寫入
* main.py 可讀取
* UI 禁止直接讀取

---

## 3.3 更新流程資料流（Data Flow）

完整資料鏈：

```
sentry_worker → trigger_update_cli → main.py manual_update
→ worker.execute_update_workflow
→ engine.generate_annotated_tree
→ formatter.main()
→ io_gateway.atomic_write(target_file)
```

worker 永不觸碰檔案；寫入一律經 io_gateway。

---

# 4. 指令協定（Command Contract）

以下為 Adapter → main.py → WSL 應遵守之 API。

---

## 4.1 list_projects

```
main.py list_projects
```

輸出：JSON array（內容對應 projects.json）

---

## 4.2 add_project

```
main.py add_project <name> <path> <output_file>
```

限制：

* path 為專案根
* output_file 可自動建立
* 衝突與無效路徑需立即回報錯誤

---

## 4.3 delete_project

```
main.py delete_project <uuid>
```

刪除後：

* 停止哨兵（若存在）
* 自 projects.json 移除

---

## 4.4 edit_project

```
main.py edit_project <uuid> <field> <new_value>
```

允許欄位：

* name
* path
* output_file（單一）
* target_files（單一）

---

## 4.5 add_target / remove_target

```
add_target <uuid> <path>
remove_target <uuid> <path>
```

target_files 影響 formatter 寫入行為。

---

## 4.6 start_sentry / stop_sentry

```
start_sentry <uuid>
stop_sentry <uuid>
```

start：

* 啟動 sentry_worker
* 傳入：uuid, project_path, target_files

stop：

* 終止該 PID

---

## 4.7 get_log

```
get_log <uuid> <lines=100>
```

由 UI 戰情室使用。
不得混合語意翻譯。

---

## 4.8 manual_update

```
manual_update <uuid>
```

執行 pipeline（engine → formatter → io_gateway）。

---

# 5. 不變性條款（Invariants）

後端永遠遵守：

1. **所有寫入必須使用 atomic_write**
2. **projects.json 是唯一真實來源（SSOT）**
3. **worker / sentry_worker 禁止寫 output files**
4. **engine / formatter 不得進行任何 I/O**
5. **UI 禁止直接讀取任何後端檔案**
6. **sentry_worker 只能寫 `.sentry_status`**
7. **新增 API 不得破壞資料格式相容性**

---

# 6. 版本策略（Version Policy）

* 任何破壞格式者 → 必須升 major version
* 增加欄位 → minor version
* 修改預設值 → patch version

---

# 7. 版權與作者

* 作者：帕爾（Par）
* 系統協作：Laplace Raven Model
* 授權：MIT License


