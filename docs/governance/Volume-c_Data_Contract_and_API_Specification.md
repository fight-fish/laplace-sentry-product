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


