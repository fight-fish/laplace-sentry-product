# Laplace Sentry

Laplace Sentry 是本地優先的專案結構監控與文件同步工具。本檔只提供程式庫起始導覽；正式治理、操作與升級邊界仍由下列文件承接。

## 開始前先讀

1. [AGENTS.md](AGENTS.md)：實作端身分、第一真相、正式輸入與修改邊界。
2. [系統憲章與架構](docs/governance/volume-a-system-constitution-and-architecture.md)：系統分層、責任與架構入口。
3. [系統入口與操作治理](docs/governance/Volume-b_System_Entry_Points_and_Operations_Manual.md)：安裝、啟動及升級入口。
4. [版本與相容性政策](docs/governance/Volume-e_Versioning_and_Compatibility_Policy.md)：版本、升級、回復與證據分級。
5. [測試入口說明](tests/README.md)：快速檢查、完整矩陣與正式環境證據的差異。

## 三個位置不可混用

| 位置 | 用途 | 修改原則 |
| --- | --- | --- |
| 本程式庫 | 開發、檢查與形成可追溯版本的主要工作樹 | 依 `AGENTS.md` 與當輪正式輸入修改 |
| Windows Frontend 正式安裝副本 | 使用者實際啟動的 Windows 前端 | 沒有正式升級或同步裁決時不得直接覆寫 |
| WSL Backend 正式執行副本 | 正式後端執行環境與受保護資料所在位置 | 沒有正式升級、驗證或回復裁決時不得直接操作 |

程式庫內完成修改或測試，不等於兩份正式執行副本已更新或驗證。

## 安裝、啟動與升級

- [install.bat](install.bat) 是首次安裝器。偵測到既有 Windows 或 WSL 正式副本時會拒絕把重新安裝當作升級。
- 日常啟動使用已安裝前端提供的啟動入口；詳細流程見[系統入口與操作治理](docs/governance/Volume-b_System_Entry_Points_and_Operations_Manual.md)。
- [upgrade.bat](upgrade.bat) 目前公開的能力只有安全預演與在指定暫存目錄建立分期套件；這兩種操作都不寫入正式 Windows 或 WSL 副本。
- 正式環境的升級前檢、準備、套用與回復屬授權制流程。不得因本檔、原始碼中存在內部能力或測試通過，就自行推定可執行正式升級。

任何正式環境升級，都必須回到當輪正式裁決確認目標、資料保護、驗證、停止與回復條件。本檔本身不授予部署、同步或正式套用權限。

