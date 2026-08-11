
# **System Entry Points & Operations Manual**

### 系統出入口與啟動治理手冊

---

## 📂 建議存放位置

```id="n8r1fd"
Laplace-Sentry-Product/
└── docs/
    └── governance/
        └── Volume-B_System_Entry_Points_and_Operations_Manual.md
```

> 📌 若尚未有 `docs/` 資料夾，建議正式建立：
> `docs/governance/` 作為「制度級文件專區」

---

## 0. Document Purpose 文件宗旨

本文件定義：

> **Laplace Sentry 系統的所有正式出入口、啟動流程與運行治理標準**

其目的為：

* 消除重啟專案時對個人記憶的依賴
* 建立可重現的標準化操作流程
* 降低部署失敗率
* 提供維運與交接依據

---

# 1. System Entry Point Matrix 系統出入口總表

## 1.1 使用者操作入口

| 類型      | 入口            | 說明           |
| ------- | ------------- | ------------ |
| UI 主入口  | `run_ui.bat`  | 啟動系統 Tray UI |
| Tray 程式 | `tray_app.py` | UI 主程式核心     |
| 系統托盤    | Windows Tray  | 使用者主要操作介面    |

---

## 1.2 系統控制入口

| 類型              | 入口                 | 說明           |
| --------------- | ------------------ | ------------ |
| Backend CLI 主入口 | `main.py`          | 後端指令分派中樞     |
| 背景守護核心          | `daemon.py`        | 專案管理與工作流控制   |
| 自動監控入口          | `sentry_worker.py` | 檔案監控與自動更新觸發器 |
| 公開升級入口          | `upgrade.bat`      | 只提供安全預演與指定 TEMP staging；不公開正式內部模式 |

---

## 1.3 系統資料入口

| 類型     | 路徑                           | 說明         |
| ------ | ---------------------------- | ---------- |
| 專案資料庫  | `Backend/data/projects.json` | 專案設定與索引    |
| 暫存治理區  | `temp/`                      | 鎖、備份、自癒資料區 |
| 專案輸出文件 | 使用者專案目錄                      | 樹狀文件輸出位置   |

---

# 2. Startup Flow Architecture 啟動流程架構

## 2.1 使用者啟動流程

```id="o0v0pj"
使用者
   ↓
run_ui.bat
   ↓
Tray UI 啟動
   ↓
載入 sentry_config.ini
   ↓
建立 Adapter 通訊橋接
   ↓
呼叫 Backend CLI
```

---

## 2.2 Backend 啟動流程

```id="l10zab"
CLI 呼叫 main.py
   ↓
指令解析 Dispatcher
   ↓
轉交 daemon.py
   ↓
判斷任務類型
   ↓
呼叫對應 Worker Pipeline
```

---

## 2.3 自動監控啟動流程

```id="azl9ko"
啟動哨兵
   ↓
建立專案快照
   ↓
週期性掃描檔案變化
   ↓
智能節流判定
   ↓
觸發 manual_update
   ↓
更新專案文件
```

---

# 3. Environment Requirements 環境需求規範

## 3.1 作業系統需求

| 項目     | 需求              |
| ------ | --------------- |
| OS     | Windows 10+     |
| 子系統    | WSL (建議 Ubuntu) |
| Python | 3.10+           |

---

## 3.2 前端依賴套件

| 套件        | 用途       |
| --------- | -------- |
| PySide6   | Qt UI 框架 |
| shiboken6 | Qt 綁定支援  |

---

## 3.3 後端依賴套件

| 套件          | 用途       |
| ----------- | -------- |
| portalocker | 檔案鎖與安全寫入 |
| pytest      | 測試框架     |

---

# 4. Standard Startup Procedure 標準啟動流程

## 4.1 初次部署流程

### Step 1 — 安裝依賴

* 安裝 Python
* 安裝 WSL
* 安裝 pip 套件

### Step 2 — 執行安裝腳本

```bash
install.bat
```

`install.bat` 只用於首次安裝。若已存在 Windows Frontend 或 WSL Backend 正式副本，安裝器會拒絕把重新安裝當作版本升級。

### Step 3 — 啟動系統

```bash
run_ui.bat
```

---

## 4.2 日常啟動流程

使用者僅需：

```bash
run_ui.bat
```

系統將自動：

* 啟動 UI
* 檢查後端可用性
* 建立橋接
* 恢復專案狀態

---

## 4.3 公開升級預演與 TEMP staging

公開入口 `upgrade.bat` 目前只接受：

- 無參數或 `--dry-run`：輸出安全升級計畫，不寫入正式副本。
- `--stage -StagingRoot PATH`：只在指定 staging root 建立套件、備份與計畫產物，不寫入正式 Windows 或 WSL runtime。

公開入口不負責停止正式程序、套用正式檔案、寫入版本標記或執行正式回復。

## 4.4 授權制正式升級流程

正式環境升級依序區分：

1. 正式預檢：唯讀核對來源、目標、程序、權限與受保護資料。
2. 正式準備：建立交易證據、原貌備份、套件與交易紀錄，但不套用。
3. 套用資格驗證：確認交易與環境仍符合正式套用條件。
4. 正式套用：依交易紀錄執行受控寫入，最後才更新版本標記。
5. 回復與復原：失敗或中斷時依交易紀錄恢復至安全狀態。

上述能力位於內部主程序與專責 helper，現役 `upgrade.bat` 不公開其內部模式。一般使用者不得把原始碼中的模式名稱當成可直接操作命令；每次正式升級都必須有當輪正式裁決、明確目標、驗證與停損條件。

---

# 5. Runtime Lifecycle Governance 運行期生命週期治理

## 5.1 前端生命週期

* 啟動 Tray
* 建立通訊橋接
* 等待使用者操作

## 5.2 後端生命週期

* 接收 CLI 指令
* 分派任務
* 呼叫工作流
* 返回結果

## 5.3 哨兵生命週期

* 建立初始快照
* 週期性監控
* 節流判定
* 自動觸發更新

---

# 6. Operational Safety Rules 操作安全規範

### 規則一：禁止直接手動修改 temp 資料夾

### 規則二：禁止強制關閉哨兵背景程序

### 規則三：projects.json 不得手動編輯

### 規則四：更新流程中不得中斷電源

---

# 7. System Recovery Procedures 系統復原流程

## 7.1 UI 無法啟動

→ 檢查 Python 環境
→ 檢查 PySide6 安裝
→ 檢查 sentry_config.ini

## 7.2 專案無法更新

→ 檢查 Backend CLI
→ 檢查哨兵狀態
→ 檢查檔案權限

## 7.3 資料損壞

→ 系統將自動從備份復原
→ 備份位於 `temp/` 對應族譜目錄

