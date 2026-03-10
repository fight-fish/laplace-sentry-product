
# **Sentry UI v1 — Windows Desktop Interface**

**Sentry UI v1** 是 Laplace Sentry Control System 的 **Windows 桌面介面**，
透過托盤圖示、雙視圖（The Eye / Dashboard）與拖曳操作，
協助使用者直覺地操作 WSL 後端的目錄監控系統。

UI 與後端透過 `adapter.py` 進行橋接，
以 WSL 指令方式呼叫後端的 `main.py` 執行監控指令。

---

# **1. 系統需求（System Requirements）**

### **作業系統**

* Windows 10 / 11

### **必要安裝**

* Python 3.10+
* WSL（已安裝 Ubuntu 或其他 Linux 發行版）
* 已啟動並安裝成功的後端專案：`laplace_sentry_control_v2`

### **UI 依賴（Windows 端）**

請於 Windows 的虛擬環境安裝以下套件：

```
PySide6==6.10.1
PySide6_Addons==6.10.1
PySide6_Essentials==6.10.1
shiboken6==6.10.1
```

UI 已附上 `requirements_win.txt` 可直接使用：

```bash
pip install -r requirements_win.txt
```

---

# **2. 專案結構（Project Structure）**

```
SENTRY_UI_v1/
├── .venv/                         # Windows 端虛擬環境
├── assets/
│   └── icons/
│       └── tray_icon.png          # 托盤圖示
│
├── src/
│   ├── backend/
│   │   ├── __init__.py
│   │   └── adapter.py             # 桥接器：連線 WSL 後端、轉換路徑並解析回傳資料
│   └── tray/
│       ├── __init__.py
│       └── tray_app.py            # UI 主入口：The Eye + Dashboard + 托盤
│
├── requirements_win.txt           # Windows UI 依賴清單
├── run_ui.bat                     # UI 啟動腳本
├── sentry_config.ini              # UI 設定檔（WSL 路徑 / 專案設定）
├── UI_Strings_Reference_v2.md     # UI 字串規範（最新版）
└── UI_Strings_Reference.md        # 舊版字串（備份）
```

---

# **3. 安裝（Installation）**

在 Windows PowerShell 或 CMD 中執行：

```bash
cd SENTRY_UI_v1

python -m venv .venv
.\.venv\Scripts\activate

pip install -r requirements_win.txt
```

**注意：**

* Windows UI 不包含後端邏輯
* 需要 WSL 後端可正常呼叫 `python main.py`
* adapter.py 會負責呼叫：

  ```
  wsl python /path/to/laplace_sentry_control_v2/main.py <指令>
  ```

---

# **4. 啟動方式（How to Launch）**

## **方法 A：使用批次檔（建議）**

直接雙擊：

```
run_ui.bat
```

批次檔會：

1. 啟動虛擬環境
2. 執行 `src/tray/tray_app.py`
3. 顯示系統托盤圖示

---

## **方法 B：使用 Python 手動啟動**

```bash
.\.venv\Scripts\activate
python src/tray/tray_app.py
```

---

# **5. 介面介紹（Interface Overview）**

UI v1 由兩大視圖與托盤介面構成：

---

## **5.1 The Eye — 生物感主視圖（View A）**

由 `SentryEyeWidget` 實作，具有：

* **眨眼動畫**
* **隨機掃視（Saccade movement）**
* **停頓與微調（生物感）**
* **進食動畫（EATING 模式）**

行為由三個主要訊號組成：

* `_trigger_saccade()`
* `_trigger_blink()`
* `QTimer` 心跳更新動畫

所有動畫皆為 PySide6 動態重繪，不依賴 GIF 或序列貼圖。

---

## **5.2 Dashboard — 控制面板（View B）**

`DashboardWidget` 提供：

* 已註冊專案列表
* 增加寫入檔（拖曳至清單）
* 啟動/停止哨兵
* 顯示最新日誌（透過 adapter 呼叫 WSL 後端）
* 顯示錯誤、成功、警告提示

兩個視圖由 `QStackedWidget` 切換：

* Eye（View A）
* Dashboard（View B）

---

# **6. 拖曳操作（Drag & Drop Behavior）**

UI 支援資料夾拖曳至 The Eye：

### **Layer 1 — 舊專案判斷**

若拖入資料夾為已註冊專案：

* 若哨兵未啟動 → 自動啟動
* 若已啟動 → 觸發一次手動更新（manual update）

---

### **Layer 2 — 智慧配對（Smart Match）**

若資料夾包含預設輸出檔（如 README / SUMMARY），會自動填入專案設定。

---

### **Layer 3 — 完整註冊流程**

若無法智慧配對：

* 開啟輸入對話框
* 使用者輸入別名與輸出檔路徑
* 系統建立全新專案

這三層行為完全由 `dropEvent()` 內的流程驅動。

---

# **7. UI ↔ 後端通訊（WSL Integration）**

WSL 通訊由 `adapter.py` 負責：

### **主要任務**

* 將 Windows 路徑轉為 WSL 相對版本
* 以 `wsl python main.py` 呼叫後端指令
* 捕捉 stdout / stderr
* 解析 JSON / 文本格式的狀態回應
* 提供 UI 能使用的方法，例如：

  * `get_log(uuid)`
  * `toggle_project_status(uuid)`
  * `manual_update(uuid)`
  * `match_project_by_path(folder)`

adapter 是 Windows UI 與 WSL 後端間的唯一橋樑。

---

# **8. 設定檔（sentry_config.ini）**

該檔案用來設定：

* 後端 Sentry 專案在 WSL 的路徑
* 是否啟用智慧配對
* UI 運作的預設參數

修改後需重新啟動 UI 才會套用。

---

# **9. 常見問題（FAQ）**

### **Q：UI 無法取得日誌？**

* WSL 端後端未啟動
* adapter 找不到後端專案路徑
* 設定檔路徑錯誤

---

### **Q：拖曳無反應？**

* 必須拖曳「資料夾」，非檔案
* 需啟用 The Eye 視圖
* Windows 權限問題可能阻擋拖曳事件

---

# **10. 版本資訊（Version Info）**

* **Sentry UI v1**

  * 主入口：`src/tray/tray_app.py`
  * 功能：托盤、雙視圖、生物感動畫、拖曳註冊、後端控制面板
  * 配對後端：`laplace_sentry_control_v2`（全測試通過）

---

# **11. 授權（License）**

MIT License


