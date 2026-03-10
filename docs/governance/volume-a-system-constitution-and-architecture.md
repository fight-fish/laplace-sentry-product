# **System Constitution & Architecture Whitepaper**

### 系統憲章與架構白皮書

---

## 0. Document Purpose 文件宗旨

本文件為 **Laplace Sentry 系統之最高制度性文件**，
用以定義系統的存在目的、架構邊界、模組職責與核心治理原則。

本文件屬於：

> **制度層文件（Constitutional-Level Document）**

其效力高於：

* 操作手冊
* 開發說明
* 任務日誌
* 臨時設計備忘

當後續文件與本文件衝突時，
**以本文件定義之制度與架構原則為最高準則。**

---

## 1. System Identity 系統定位

### 1.1 System Name

**Laplace Sentry**

### 1.2 System Nature

本系統屬於：

> **Local-First Intelligent Project Sentinel System**
> 本地優先之智慧專案監控與結構治理系統

### 1.3 System Mission 系統使命

Laplace Sentry 的核心使命為：

> **以結構化方式持續監控專案狀態，
> 並自動維護專案文件與結構映射的一致性。**

### 1.4 Core Functional Domains 核心職能領域

本系統專責以下領域：

1. 專案檔案結構解析
2. 樹狀結構標註生成
3. 專案文件自動同步更新
4. 檔案變動監控與節流治理
5. 安全資料寫入與備份復原
6. 前後端操作橋接與控制流轉換

---

## 2. System Architectural Philosophy 系統架構哲學

### 2.1 Layered Responsibility 分層責任制

系統採用嚴格分層架構：

| 層級                   | 職責         |
| -------------------- | ---------- |
| UI Layer             | 使用者操作與視覺呈現 |
| Adapter Layer        | 前後端橋接與指令轉換 |
| Control Layer        | 任務分派與流程控制  |
| Worker Layer         | 純運算處理      |
| Engine Layer         | 結構生成與核心演算法 |
| I/O Governance Layer | 安全寫入與資料保護  |

### 2.2 Single Source of Truth (SSOT)

所有系統關鍵狀態皆需具備唯一權威來源：

| 項目     | SSOT 模組         |
| ------ | --------------- |
| 路徑結構   | `path.py`       |
| 資料寫入   | `io_gateway.py` |
| 專案資料   | `projects.json` |
| 樹狀生成邏輯 | `engine.py`     |
| 工作流    | `worker.py`     |

### 2.3 Separation of Concerns 關注點分離

禁止跨層污染：

* UI 不得直接操作資料層
* Worker 不得執行 I/O
* Engine 不得涉及流程控制
* I/O 層不得修改業務邏輯

---

## 3. System Topology 系統拓撲結構

### 3.1 High-Level Architecture 高階架構

```
[ User ]
   ↓
[ Tray UI ]
   ↓
[ Adapter Bridge ]
   ↓
[ Backend CLI Dispatcher ]
   ↓
[ Daemon Controller ]
   ↓
[ Worker Pipeline ]
   ↓
[ Engine ]
   ↓
[ I/O Gateway ]
   ↓
[ File System ]
```

### 3.2 Control Flow 控制流

系統控制流遵循：

> **UI → Adapter → CLI → Daemon → Worker → Engine → I/O**

### 3.3 Data Flow 資料流

資料流遵循：

> **File System → Engine → Worker → Formatter → I/O → Output Files**

---

## 4. Subsystem Responsibilities 子系統責任定義

### 4.1 UI Subsystem

**性質：操作層**

職責：

* 提供使用者操作入口
* 顯示專案資訊
* 傳遞操作指令
* 不保存正式資料

---

### 4.2 Adapter Subsystem

**性質：橋接層**

職責：

* 將 UI 操作轉換為 CLI 指令
* 管理前後端通訊格式
* 不涉及業務邏輯

---

### 4.3 Backend Control Subsystem

**性質：調度中樞**

職責：

* 任務分派
* 工作流控制
* 守護進程管理
* 專案狀態管理

---

### 4.4 Worker Subsystem

**性質：純運算層**

職責：

* 執行更新工作流
* 不得進行檔案寫入
* 僅負責資料轉換與加工

---

### 4.5 Engine Subsystem

**性質：核心演算層**

職責：

* 專案檔案解析
* 樹狀結構生成
* 註解合併與結構對齊

---

### 4.6 I/O Governance Subsystem

**性質：資料治理層**

職責：

* 原子寫入保護
* 檔案鎖管理
* 備份保存
* 損壞自動復原

---

## 5. System Boundary Definitions 系統邊界定義

### 5.1 系統負責範圍

✔ 專案結構治理
✔ 文件同步更新
✔ 檔案監控與觸發
✔ 本地資料保護

### 5.2 系統不負責範圍

✘ Git 版本控制
✘ 雲端同步
✘ 專案原始碼編輯
✘ 外部建置流程

---

## 6. Core Governance Principles 核心治理原則

### 原則一：資料安全優先

所有寫入必須具備：

* 檔案鎖
* 備份機制
* 原子替換
* 自癒能力

---

### 原則二：模組不可越權

任何模組不得執行未授權職責。

---

### 原則三：結構一致性優先

專案文件必須與實際結構保持一致。

---

### 原則四：可恢復性設計

系統必須能在錯誤後恢復到安全狀態。

---

### 原則五：可觀測性設計

所有關鍵流程必須可追蹤、可診斷。

---

## 7. Constitutional Authority 憲章效力聲明

本文件為：

> **Laplace Sentry 最高制度文件**

未來：

* 架構變更
* 模組職責調整
* 資料契約變更

皆需符合本憲章原則。

<!-- AUTO_TREE_START -->
```
Laplace-Sentry-Product/                                            # Sentry 專案根目錄；包含前端、後端、文件與安裝腳本
├── Backend/                                                       # 後端主體；負責專案資料管理、目錄樹生成、監控控制與安全寫入
│   ├── data/                                                      # 後端資料目錄；存放系統正式使用的持久化資料
│   │   └── projects.json                                          # 已註冊專案資料庫；保存專案基本資訊、輸出目標與忽略規則
│   ├── src/                                                       # 後端原始碼目錄
│   │   └── core/                                                  # 後端核心模組；集中放置控制、運算、路徑與 I/O 治理邏輯
│   │       ├── __init__.py                                        # Python 套件初始化檔；讓 core 可被作為模組匯入
│   │       ├── daemon.py                                          # 後端調度中樞；負責 CLI 指令分派、專案管理與工作流協調
│   │       ├── engine.py                                          # 結構生成核心；負責掃描專案並產生註解樹與結構化樹資料
│   │       ├── formatter.py                                       # 輸出包裝器；負責將原始樹內容套用指定格式策略
│   │       ├── io_gateway.py                                      # 安全寫入閘門；負責加鎖、備份、原子替換與損壞自癒
│   │       ├── path.py                                            # 路徑治理中心；提供專案根目錄、temp 族譜與跨平台路徑正規化
│   │       ├── sentry_worker.py                                   # 背景哨兵程序；監控檔案變動並在有效變更時觸發自動更新
│   │       └── worker.py                                          # 單次更新工作流；串接 engine 與 formatter 完成一次生產流程
│   ├── main.py                                                    # 後端 CLI 入口；系統對外主要指令進入點
│   └── requirements.txt                                           # 後端依賴清單；定義執行與測試所需 Python 套件
├── Frontend/                                                      # 前端主體；負責 Tray UI、互動顯示與前後端橋接
│   ├── assets/                                                    # 前端資源目錄；存放圖示等靜態素材
│   │   └── icons/                                                 # UI 圖示資源目錄
│   │       ├── cyber-eye.ico                                      # 哨兵之眼圖示；主要用於系統托盤或視窗圖示
│   │       └── tray_icon.png                                      # Tray 圖示圖片；前端介面使用的圖像資產
│   ├── src/                                                       # 前端原始碼目錄
│   │   ├── backend/                                               # 前端橋接層；負責從 UI 呼叫後端 CLI/Daemon
│   │   │   ├── __init__.py                                        # Python 套件初始化檔；讓 frontend.backend 可被匯入
│   │   │   └── adapter.py                                         # 前後端橋接器；把 UI 操作轉為後端可執行的命令呼叫
│   │   └── tray/                                                  # Tray UI 模組；負責哨兵之眼與控制台介面
│   │       ├── __init__.py                                        # Python 套件初始化檔；讓 tray 模組可被匯入
│   │       └── tray_app.py                                        # 前端主程式；實作 Tray UI、控制台、目錄樹顯示與互動邏輯
│   ├── requirements.txt                                           # 前端依賴清單；定義 PySide6 等 UI 執行所需套件
│   ├── run_ui.bat                                                 # 前端啟動腳本；供 Windows 直接啟動 Sentry UI
│   └── sentry_config.ini                                          # 前端設定檔；保存 UI 偏好設定，如眼球尺寸等參數
├── docs/                                                          # 正式文件中心；存放治理文件、手冊與 UI 規範
│   ├── governance/                                                # 制度治理文件區；存放系統憲章、契約、穩定性與版本政策
│   │   ├── Volume-b_System_Entry_Points_and_Operations_Manual.md  # 系統出入口與啟動治理文件；定義啟動流程與運作方式
│   │   ├── Volume-c_Data_Contract_and_API_Specification.md        # 資料契約與 API 規格；定義 TreeNode 與模組交換介面
│   │   ├── Volume-d_Error_Codes_and_Stability_Governance.md       # 錯誤碼與穩定性治理文件；定義錯誤分級與恢復原則
│   │   ├── Volume-e_Versioning_and_Compatibility_Policy.md        # 版本與相容性政策；規範未來升級與破壞性變更流程
│   │   └── volume-a-system-constitution-and-architecture.md       # 系統憲章與架構白皮書；整套系統的最高架構與治理基準
│   ├── manuals/                                                   # 手冊子目錄；存放偏操作導向的正式手冊文件
│   │   └── Volume-f_User_Operations_Manual.md                     # 使用者操作手冊；提供 UI 與系統日常使用說明
│   └── ui/                                                        # UI 專屬規範區；存放字串、介面語意與互動規格
│       └── Sentry_UI_String_and_Interface_Specification.md        # UI 唯一正式規範書；定義字串、介面語意、Toast、日誌翻譯與時間軸規則
├── .gitignore                                                     # Git 忽略規則；避免不該納入版本控制的檔案被提交
├── install.bat                                                    # 安裝腳本；負責建立或部署 Sentry 執行環境
└── uninstall.bat                                                  # 移除腳本；負責卸載或清理 Sentry 相關部署內容
```
<!-- AUTO_TREE_END -->
