## 0. Document Purpose 文件宗旨

本文件為 **Laplace Sentry 系統所有資料格式與介面協定的最高契約文件**。

其目的為：

* 定義正式資料結構（Schema）
* 建立模組間資料交換標準
* 防止欄位漂移與型別混亂
* 建立 API 相容性準則
* 作為未來版本升級依據

本文件屬於：

> **資料憲法層級文件（Data Constitutional Document）**

---

# 1. Core Data Governance Principles 核心資料治理原則

### 原則一：Schema First

所有資料格式必須先定義結構，方可實作。

### 原則二：Strong Contract

模組間資料交換必須遵守契約，不得隱式推論。

### 原則三：Forward Compatibility

新增欄位不得破壞舊版解析能力。

### 原則四：Single Responsibility

資料模型僅描述結構，不包含業務邏輯。

---

# 2. Primary Data Structures 主要資料結構定義

---

## 2.1 TreeNode Schema 樹狀節點結構（核心憲法）

### ■ 用途

描述專案檔案結構之標準表示方式。

### ■ JSON Schema 定義

```json
{
  "name": "string",
  "path_key": "string",
  "is_dir": "boolean",
  "comment": "string|null",
  "children": "TreeNode[]"
}
```

### ■ 欄位語意定義

| 欄位       | 型別          | 必填 | 說明             |
| -------- | ----------- | -- | -------------- |
| name     | string      | ✔  | 檔案或資料夾名稱       |
| path_key | string      | ✔  | 相對專案根目錄的唯一識別路徑 |
| is_dir   | boolean     | ✔  | 是否為資料夾         |
| comment  | string/null | ✘  | 使用者自訂註解        |
| children | array       | ✔  | 子節點清單          |

### ■ 不變量（Invariants）

1. `path_key` 必須唯一
2. 資料夾節點必須允許 children
3. 檔案節點 children 必為空陣列
4. 結構不得形成循環參照


## 2.1.1 TreeNode Comment Persistence Rule 樹節點註解持久化規則

### ■ 用途

定義 TreeNode.comment 欄位在使用者編輯後的資料持久化來源與更新流程。

### ■ 持久化來源

在 S-02-02b v1 階段：

TreeNode.comment 的資料持久化來源為：

> target markdown 檔案中既有對應節點的註解位置

系統不建立獨立 annotation 檔案，不新增資料庫層。

### ■ 單點更新定位依據

節點註解更新必須同時具備：

| 條件 | 說明 |
|------|------|
| uuid | 專案唯一識別碼 |
| path_key | 節點相對專案根目錄之唯一識別路徑 |

兩者缺一不可。

### ■ 更新流程約束

1. UI 僅可提交 comment 新值
2. 不得由 UI 直接寫入檔案
3. 必須透過正式 daemon 指令進行寫入
4. 寫入後必須重新解析目錄樹
5. UI 顯示結果以重新解析之樹資料為準

### ■ 相容性說明

本規則：

- 不改變既有 TreeNode Schema 結構
- 不影響 manual_update 既有寫入流程
- 不新增額外資料儲存層


---

## 2.2 Project Record Schema 專案紀錄結構

### ■ 用途

描述系統內管理之專案資訊。

### ■ JSON Schema

```json
{
  "uuid": "string",
  "name": "string",
  "root_path": "string",
  "output_file": "string",
  "target_files": "string[]",
  "ignore_patterns": "string[]"
}
```

### ■ 欄位說明

| 欄位              | 型別     | 說明       |
| --------------- | ------ | -------- |
| uuid            | string | 專案唯一識別碼  |
| name            | string | 專案名稱     |
| root_path       | string | 專案根目錄    |
| output_file     | string | 主要輸出文件   |
| target_files    | array  | 額外更新目標文件 |
| ignore_patterns | array  | 忽略路徑規則   |

---

# 3. API Contract Definitions API 介面契約定義

---

## 3.1 Adapter ⇄ Backend CLI Contract

### ■ 通訊形式

Adapter 必須透過 CLI 呼叫 Backend：

```bash
python main.py <command> <args>
```

### ■ 回傳標準

| 類型 | 格式                 |
| -- | ------------------ |
| 成功 | JSON               |
| 失敗 | STDERR + Exit Code |


## 3.1.1 save_tree_comment CLI Contract

### ■ 用途

提供單一節點註解之正式回寫指令介面。

---

### ■ 指令格式

```bash
python main.py save_tree_comment <uuid> <path_key> <comment>
````

---

### ■ 參數定義

| 參數       | 型別     | 說明          |
| -------- | ------ | ----------- |
| uuid     | string | 專案唯一識別碼     |
| path_key | string | 節點唯一識別路徑    |
| comment  | string | 使用者編輯後之註解內容 |

---

### ■ 成功回傳格式（STDOUT）

```json
{
  "ok": true,
  "uuid": "<uuid>",
  "path_key": "<path_key>",
  "comment": "<updated_comment>"
}
```

---

### ■ 失敗行為（STDERR + Exit Code）

| Exit Code | 錯誤類型         |
| --------- | ------------ |
| 1         | 參數數量錯誤       |
| 2         | uuid 不存在     |
| 3         | path_key 不存在 |
| 4         | 寫入流程失敗       |
| 5         | 檔案鎖定或 I/O 錯誤 |

STDERR 必須輸出可讀錯誤訊息，不得靜默失敗。

---

### ■ 相容性聲明

本指令：

* 不影響既有 manual_update 指令語意
* 不改變既有 CLI 指令參數順序
* 不新增破壞性資料格式
* 不改變既有 safe_write 流程

---

## 3.2 Daemon Internal API Contract

Daemon 對 Worker 呼叫介面：

```python
execute_update_workflow(
    project_path: str,
    target_doc: str,
    old_content: str,
    ignore_patterns: Optional[Set[str]]
) -> tuple[int, str]
```

### ■ 回傳契約

| 回傳值 | 說明    |
| --- | ----- |
| 0   | 成功    |
| 3   | 工作流錯誤 |

---

## 3.3 Engine API Contract

```python
generate_annotated_tree(
    project_path: str,
    old_content: str,
    ignore_patterns: Optional[Set[str]]
) -> str
```

輸出：

> 樹狀結構文字表示（未格式化）

---

## 3.4 Formatter API Contract

```bash
formatter.py --strategy <type>
```

| Strategy | 說明          |
| -------- | ----------- |
| raw      | 原始輸出        |
| obsidian | Markdown 包裝 |

---

# 4. Data Persistence Governance 資料持久化治理

---

## 4.1 Safe Write Protocol

所有寫入必須遵守：

1. File Lock
2. Temp Write
3. Atomic Replace
4. Backup Rotation
5. Self-Healing Recovery

---

## 4.2 Backup Naming Convention

```text
<filename>.<timestamp>.bak
```

範例：

```text
projects.json.20260310-153015.bak
```

---

# 5. Compatibility Policy 相容性政策

| 類型   | 政策 |
| ---- | -- |
| 新增欄位 | 允許 |
| 刪除欄位 | 禁止 |
| 重新命名 | 禁止 |
| 型別變更 | 禁止 |

---

# 6. Schema Evolution Governance 結構演進治理

若需修改 Schema：

1. 建立新版本號
2. 提供 Migration 工具
3. 保留舊版解析能力
4. 更新本憲法文件

---

# 7. Constitutional Authority 憲法效力聲明

本文件為：

> **Laplace Sentry 所有資料結構與 API 介面之最高契約文件**

未來所有資料與介面變更，
必須先更新本文件後方可實作。


