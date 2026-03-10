### 🟢 1. `UI_Strings_Reference_v2.md` (UI 字串規範)

  * **狀態**：**完美 (Perfect)**。
  * **評語**：這份文件清楚列出了 v2.0 介面的所有文字（氣泡、按鈕、日誌翻譯）。這是前端開發的重要參考。
  * **行動**：請確保這份內容是存在 **`Frontend/UI_Strings_Reference_v2.md`** 裡。

-----

### 🟢 2. `releases.md` (版本紀錄)

  * **狀態**：**完美 (Perfect)**。
  * **評語**：清楚記錄了 v7.2.0 的里程碑意義，以及從 v1 到 v7 的演進。這對開源專案來說非常加分。
  * **行動**：請確保這份內容是存在 **`Backend/releases.md`** 裡。

-----

### 🔴 3. `Backend README` (後端說明書)

  * **狀態**：**有一處錯誤 (Error Found)**。
  * **錯誤點**：在 **5.2 CLI 指令** 章節中，`add_project` 的參數順序和數量寫錯了。
      * **文件寫法**：`add_project <project_dir> <output_md> [alias]` (把別名當作選填且放在最後)
      * **真實程式碼 (`daemon.py`)**：嚴格要求 3 個參數，且順序是 `name, path, output_file`。
  * **後果**：如果照著文件打，程式會報錯「參數數量不正確」或把路徑當成名字存進去。

### 🛠️ 修正方案：更新 Backend README

請在你的 **桌面 `Laplace-Sentry-Product` 資料夾** 中，找到 **`Backend/README.md`**，並用以下 **修正後的版本** 完全覆蓋它。

**(我已修正第 5.2 節的指令格式，並微調了安裝指令以符合我們精簡後的依賴)**

```markdown
# 🆕《Laplace Sentry Control — Backend README（WSL 專用版）》

# **1. 專案簡介（Overview）**

**Laplace Sentry Control System** 是一套針對本地環境設計的 **穩定、高可預測性目錄監控系統**。
後端（WSL）負責：

* 多專案監控（multi-sentry）
* 目錄快照與變化比對
* 靜默機制（SmartThrottler）
* 原子寫入（atomic write）
* 狀態檔輸出與審計能力
* 供前端 UI 呼叫的統一 CLI 入口

所有核心流程皆可審計、可測試、可預期。

---

# **2. 系統需求（WSL / Backend Requirements）**

### **作業系統**

* WSL（Ubuntu 或其他 Linux 發行版）
* Python 3.10+

### **第三方依賴（Runtime 必要）**

```

portalocker==3.2.0

````

---

# **3. 安裝（Installation）**

通常由 Windows 安裝包 (`install.bat`) 自動處理。若需手動安裝：

```bash
# 假設已位於專案目錄
python3 -m venv .venv
source .venv/bin/activate
pip install portalocker==3.2.0
````

-----

# **4. 專案目錄結構（Backend Structure）**

```
laplace_sentry_control_v2/        # 專案根目錄
├── data/
│   └── projects.json             # 專案設定唯一來源
├── src/
│   └── core/                     # 後端核心邏輯
│       ├── daemon.py             # 管理生命週期、事件分派
│       ├── sentry_worker.py      # 哨兵監控流程
│       ├── io_gateway.py         # 原子寫入 I/O
│       └── ...
├── main.py                       # 後端入口（WSL CLI）
├── PROTOCOL.md                   # API 契約
└── releases.md                   # 版本紀錄
```

-----

# **5. 使用方式（Usage — WSL Backend）**

所有操作皆需 **在專案根目錄** 進行。

### **5.1 啟動主控制台（推薦）**

```bash
source .venv/bin/activate
python main.py
```

### **5.2 CLI 指令（單次操作模式）**

**1. 列出所有專案**

```bash
python main.py list_projects
```

**2. 新增專案 (注意參數順序)**

```bash
# 格式: add_project <專案別名> <專案路徑> <目標寫入檔>
python main.py add_project "MyProject" "/mnt/d/Obsidian/MyNotes" "/mnt/d/Obsidian/MyNotes/README.md"
```

**3. 啟動 / 停止哨兵**

```bash
python main.py start_sentry <uuid>
python main.py stop_sentry <uuid>
```

**4. 讀取專案日誌**

```bash
python main.py get_log <uuid> [lines]
```

**5. 手動更新**

```bash
python main.py manual_update <uuid>
```

**6. 管理忽略規則**

```bash
# 列出候選
python main.py list_ignore_candidates <uuid>
# 固化靜默項目
python main.py add_ignore_patterns <uuid>
```

-----

# **6. 測試（Testing）**

若需執行完整測試套件（需安裝 pytest）：

```bash
pip install pytest
pytest
```

-----

# **7. 授權與作者**

  * **License**: MIT License
  * **Author**: Par (帕爾)
  * **Co-pilot**: Laplace Raven Persona AI

<!-- end list -->

```

