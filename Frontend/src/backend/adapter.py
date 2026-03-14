# src/backend/adapter.py

# 這裡，我們用「from __future__ import annotations」來確保所有的型別提示（annotations）
# 都以字串的形式處理，這是一個為了未來 Python 版本相容性的預備動作。
from __future__ import annotations

# 導入（import）dataclass 工具，方便建立只有資料的類別（不需要寫 __init__）。
from dataclasses import dataclass, field
# 導入（import）路徑處理（pathlib）中的 Path 工具。
from pathlib import Path
# 導入（import）類型提示（typing）中的 Literal（字面量）、List（列表）、Dict（字典）和 Optional（可選的）。
from typing import Literal, List, Dict, Optional, Any
# 導入（import）json 模組，用於讀取和寫入 JSON 格式的設定檔。
import json
import subprocess

# ============================
#  型別定義（給 tray_app 使用）
# ============================

# 這裡，我們用 Literal 來定義（define）專案狀態（ProjectStatus）的類型，
# 它只能是 "monitoring"（監控中）或 "stopped"（已停止）其中之一。
ProjectStatus = Literal["monitoring", "stopped"]
# 定義（define）專案模式（ProjectMode）的類型，它只能是 "silent"（靜默）或 "interactive"（互動）其中之一。
ProjectMode = Literal["silent", "interactive"]

# ============================
#  例外型別（給 tray_app 使用）
# ============================

# 這裡，我們用「class」來定義（define）一個新的錯誤類型（BackendError），
# 讓它可以繼承（Exception）Python 內建的例外處理機制。
class BackendError(Exception):
    # 這個註釋（"""..."""）是說明文件，解釋這個錯誤類型的作用。
    """
    UI 專用的後端錯誤封裝。

    - 目前 stub 版本只用來在 adapter / tray_app 之間傳遞錯誤訊息。
    - 未來若接上真正的 Laplace Sentry daemon，可以在這裡加上
    error_code / kind 等欄位，統一映射 daemon 傳回的錯誤。
    """
    # 這裡用 pass 意思是不需要為這個錯誤類型添加額外的程式碼。
    pass

# ============================
#  WSL 設定 (Installer Standard)
# ============================
# 1. 【關鍵】改用波浪號 (~) 代表使用者的 Home 目錄
# 安裝包 (install.bat) 會負責將後端檔案放入此位置
WSL_PROJECT_ROOT = "~/.laplace_sentry_backend"

# 2. Python 路徑 (指向該目錄下的 .venv)
# 注意：wsl 指令能解析 ~ 路徑
WSL_PYTHON = f"{WSL_PROJECT_ROOT}/.venv/bin/python"

# 3. 最後定義主腳本路徑
WSL_MAIN_SCRIPT = "src.core.daemon"

# 這裡，我們用「@dataclass」標記（mark）這是一個資料類別（只有數據）。
@dataclass
class ProjectInfo:
    """
    給 UI 用的專案資訊：
    - name / status / mode：tray_app 目前已經在使用
    - path / output_file / target_files：從 projects.json 讀出的真實欄位
    """
    # 這是專案的唯一識別碼（uuid），型別是字串（str）。
    uuid: str
    # 專案名稱（name），型別是字串（str）。
    name: str
    # 專案狀態（status），型別是我們上面定義的 ProjectStatus。
    status: ProjectStatus
    # 專案模式（mode），型別是我們上面定義的 ProjectMode。
    mode: ProjectMode
    # 專案的路徑（path），預設（= ""）是空字串。
    path: str = ""
    # 輸出檔案的路徑列表（output_file），預設是空的列表（用 default_factory=list）。
    # 我們這裡用「列表（List）」來指代「空籃子」。
    output_file: List[str] = field(default_factory=list)
    # 目標監控檔案的路徑列表（target_files），預設是空的列表（用 default_factory=list）。
    target_files: List[str] = field(default_factory=list)


# 這裡，我們用「@dataclass」標記（mark）這是忽略設定的資料類別。
@dataclass
class IgnoreSettings:
    # 哨兵忽略的樣式列表（List[str]）。
    sentry_ignore_patterns: List[str]
    # 目錄樹的深度限制（int），型別是整數。
    tree_depth_limit: int

# ============================
#  內部用模型（真實 projects.json）
# ============================
# 這裡，我們用「@dataclass」標記（mark）這是一個資料類別，
# 用於內部（前面帶 _），代表從 projects.json 讀出來的**原始專案資料**。
@dataclass
class _RawProject:
    # 這是專案的唯一識別碼（uuid）。
    uuid: str
    # 專案名稱。
    name: str
    # 專案路徑。
    path: str
    # 輸出檔案的路徑列表（List[str]）。
    output_file: List[str]
    # 目標監控檔案的列表。
    target_files: List[str]


# 這裡，我們用「@dataclass」標記（mark）這是一個資料類別，
# 用於內部（前面帶 _），代表專案**目前執行的狀態**（例如：有沒有在監控）。
@dataclass
class _RuntimeState:
    # 預設狀態（status）是「monitoring」（監控中）。
    status: ProjectStatus = "monitoring"
    # 預設模式（mode）是「silent」（靜默）。
    mode: ProjectMode = "silent"


# ============================
#  Adapter 本體（封裝真實資料）
# ============================


# 這裡，我們用「class」來定義（define）Adapter 類別，它負責所有後端資料的溝通。
class BackendAdapter:
    # 這個註釋（"""..."""）是說明文件，解釋這個類別的作用。
    """
    Adapter v0.9.2

    - 讀取真實 projects.json（Laplace Sentry Control）
    - 內部使用 _RawProject + _RuntimeState
    - 對外提供 ProjectInfo / list_projects / toggle_project_status / get_ignore_settings
    """

    # 這裡，我們用「def」來定義（define）Adapter 物件被建立時會自動執行的函式（__init__）。
    def __init__(self, json_path: str | Path) -> None:
        # 將設定檔的路徑（json_path）存入實例變數。
        self.json_path = Path(json_path)

        # 真實的 projects.json → _RawProject
        # 建立一個叫 _projects 的「空籃子」（List[_RawProject]），用來存放所有原始專案資料。
        self._projects: List[_RawProject] = []

        # 虛擬 runtime 狀態（uuid -> 狀態）
        # 建立一個叫 _runtime 的「有標籤的盒子」（Dict），用來存放專案的執行狀態。
        # 標籤（key）是 uuid，盒子裡面的內容（value）是 _RuntimeState 物件。
        self._runtime: Dict[str, _RuntimeState] = {}

        # 暫時寫死（之後可改成可編輯）
        # # TODO: 這裡之後要改成可編輯的設定。
        # 建立一個忽略設定（IgnoreSettings）物件，並暫時給定寫死的預設值。
        self._ignore_settings = IgnoreSettings(
            sentry_ignore_patterns=["*.tmp", "*.log"],
            tree_depth_limit=3,
        )

        # 【核心修改】停止在初始化時讀取實體檔案！
        # 我們現在依賴 list_projects() 動態去 WSL 撈資料。
        # self._load_projects_json()


    def _run_wsl_command(self, cmd: str, *args: str) -> list | dict | str:
        """
        核心通訊橋樑 (v3.2 shell-safe 參數版)：
        1. 將 Windows 反斜線路徑轉為正斜線
        2. 對每個參數做 shell-safe quoting，避免 ()、空白、# 等字元被 bash 誤解
        3. 維持既有 JSON / OK 解析策略
        """
        import shlex

        clean_args = [str(a).replace("\\", "/") for a in args]

        quoted_parts = [
            WSL_PYTHON,
            "-m",
            shlex.quote(WSL_MAIN_SCRIPT),
            shlex.quote(cmd),
            *[shlex.quote(a) for a in clean_args],
        ]
        command_string = " ".join(quoted_parts)

        full_cmd = [
            "wsl",
            "--cd",
            WSL_PROJECT_ROOT,
            "bash",
            "-lc",
            command_string,
        ]

        try:
            result = subprocess.run(
                full_cmd,
                capture_output=True,
                text=True,
                encoding="utf-8",
                creationflags=0x08000000,
                check=True,
            )

            output = result.stdout.strip()

            if not output:
                return []

            try:
                return json.loads(output)
            except json.JSONDecodeError:
                pass

            try:
                l_idx = output.find("[")
                r_idx = output.rfind("]")
                if l_idx != -1 and r_idx != -1 and r_idx > l_idx:
                    return json.loads(output[l_idx : r_idx + 1])

                l_idx = output.find("{")
                r_idx = output.rfind("}")
                if l_idx != -1 and r_idx != -1 and r_idx > l_idx:
                    return json.loads(output[l_idx : r_idx + 1])
            except json.JSONDecodeError:
                pass

            if result.returncode == 0:
                return "OK"

            raise BackendError(f"資料解析失敗 (非 JSON 且無法識別為 OK): {output}")

        except subprocess.CalledProcessError as e:
            error_msg = e.stderr.strip() or "未知錯誤"
            raise BackendError(f"WSL 執行失敗: {error_msg}")
        except Exception as e:
            raise BackendError(f"系統錯誤: {e}")
    # ---------------------------------------------------------
    # 讀取 projects.json
    # ---------------------------------------------------------

    # 這裡，我們用「def」來定義（define）載入 JSON 專案列表的函式。
    def _load_projects_json(self) -> None:
        """從 json 檔載入專案列表，填入 _projects 與 _runtime。"""
        # 讀取（read_text）JSON 檔案的全部內容，並指定編碼（encoding="utf-8"）。
        text = self.json_path.read_text(encoding="utf-8")
        # 呼叫（call）json.loads 函式，把 JSON 格式的文字轉換成 Python 的列表或字典（raw_items）。
        raw_items = json.loads(text)

        # 清空（clear）舊有的專案列表「空籃子」（_projects）。
        self._projects.clear()

        # # DEFENSE: 這裡用 DEFENSE 標籤標註，這是防呆檢查。
        # 用「if」來判斷：如果（if）讀進來的不是一個列表（list）...
        if not isinstance(raw_items, list):
            # 就用「return」結束這個載入函式。
            return

        # 我們用「for...in...」這個結構，來一個一個地（for）處理 JSON 列表中的每一個項目（item）。
        for item in raw_items:
            # # DEFENSE: 這裡再次防呆，檢查項目是不是一個字典（dict）。
            # 用「if」來判斷：如果（if）項目不是字典...
            if not isinstance(item, dict):
                # 就用「continue」跳過這一個項目，處理下一個。
                continue

            # 從字典（item）中獲取（get）uuid 欄位的值，如果沒有就用空字串，並強制轉成字串。
            uuid = str(item.get("uuid") or "")
            # 獲取 name 欄位的值。
            name = str(item.get("name") or "")
            # 獲取 path 欄位的值。
            path = str(item.get("path") or "")

            # 獲取 output_file 欄位的值，如果沒有就用空列表（[]）。
            output_file = item.get("output_file") or []
            # 獲取 target_files 欄位的值。
            target_files = item.get("target_files") or []

            # # DEFENSE: 檢查必要的欄位 uuid 和 name 是否為空。
            # 用「if」來判斷：如果（if）uuid 或 name 是空的...
            if not uuid or not name:
                # 就用「continue」跳過這一個專案。
                continue

            # # DEFENSE: 確保 output_file 是列表，不是的話就給它一個空列表。
            if not isinstance(output_file, list):
                output_file = []
            # # DEFENSE: 確保 target_files 是列表，不是的話就給它一個空列表。
            if not isinstance(target_files, list):
                target_files = []

            # 建立（instantiate）一個 _RawProject 物件，把讀到的所有資料傳入。
            # list(map(str, ...)) 是為了確保列表裡面的每個元素都是字串。
            proj = _RawProject(
                uuid=uuid,
                name=name,
                path=path,
                output_file=list(map(str, output_file)),
                target_files=list(map(str, target_files)),
            )
            # 把新的 _RawProject 物件加入（append）到 _projects 列表（空籃子）中。
            self._projects.append(proj)

            # 給新專案預設 runtime 狀態
            # 用「if」來判斷：如果（if）這個專案的 uuid 不在 runtime 盒子（_runtime）裡面...
            if uuid not in self._runtime:
                # 就建立一個預設的 _RuntimeState() 物件，並用 uuid 作為標籤（key）放進盒子。
                self._runtime[uuid] = _RuntimeState()

# ---------------------------------------------------------
    # 內部：把 _RawProject + _RuntimeState → ProjectInfo
    # ---------------------------------------------------------

    # 這裡，我們用「def」來定義（define）內部轉換函式，把兩種內部資料結構成為 UI 用的 ProjectInfo。
    def _to_project_info(self, raw: _RawProject) -> ProjectInfo:
        # 從 runtime 盒子（_runtime）中，用 uuid 標籤（raw.uuid）取出狀態。
        # 如果沒找到（get() 的結果是 None），就給它一個預設的 _RuntimeState()。
        state = self._runtime.get(raw.uuid) or _RuntimeState()
        # 建立（return）並回傳（return）一個 ProjectInfo 物件。
        return ProjectInfo(
            # uuid 和 name 直接從原始資料（raw）中複製。
            uuid=raw.uuid,
            name=raw.name,
            # status 和 mode 從狀態資料（state）中獲取。
            status=state.status,
            mode=state.mode,
            # 其餘欄位也從原始資料（raw）中複製。
            path=raw.path,
            output_file=list(raw.output_file),
            target_files=list(raw.target_files),
        )

    # ---------------------------------------------------------
    # 給 UI 用的介面（instance 版本）
    # ---------------------------------------------------------

# ... (在 BackendAdapter 類別內)

    def list_projects(self) -> List[ProjectInfo]:
        """
        【真實化】呼叫 WSL 獲取專案列表，並轉換為 UI 格式。
        """
        # 1. 呼叫 WSL 指令：list_projects
        # 這會執行：wsl python3 main.py list_projects
        raw_data = self._run_wsl_command("list_projects")

        # 2. 清空舊快取
        self._projects.clear()
        self._runtime.clear() # 真實模式下，我們依賴後端狀態，這裡先清空

        # 3. 轉換資料
        if not isinstance(raw_data, list):
            return []

        result_list = []

        for item in raw_data:
            # 安全獲取欄位
            uuid = str(item.get("uuid", ""))
            name = str(item.get("name", ""))
            status = item.get("status", "stopped") # 後端現在有真實狀態了
            
            # 將後端狀態映射到前端型別 (簡單映射)
            # 後端: running, stopped, invalid_path, muting
            # 前端 ProjectStatus: "monitoring", "stopped"
            # 前端 ProjectMode: "silent", "interactive" (暫時依賴 muting 判斷)
            
            ui_status: ProjectStatus = "monitoring" if status == "running" else "stopped"
            ui_mode: ProjectMode = "silent" if status == "muting" else "interactive"

            # 建立 ProjectInfo 物件
            info = ProjectInfo(
                uuid=uuid,
                name=name,
                status=ui_status,
                mode=ui_mode,
                path=str(item.get("path", "")),
                output_file=item.get("output_file", []),
                target_files=item.get("target_files", [])
            )
            result_list.append(info)
            
            # (選擇性) 同步更新內部 _projects 列表，以備其他舊邏輯使用
            # 這裡為了簡單，我們直接回傳轉換好的列表，暫不維護 _RawProject 的複雜映射
            
        return result_list

    # 這裡，我們用「def」來定義（define）切換專案狀態的函式。
    def toggle_project_status(self, key: str) -> Optional[ProjectInfo]:
        """
        【真實化】發送 start/stop_sentry 指令給 WSL。
        流程：
        1. 獲取當前真實狀態 (list_projects)
        2. 判斷要 Start 還是 Stop
        3. 發送指令
        4. 回傳更新後的狀態
        """
        # 1. 獲取最新狀態 (這是 Source of Truth)
        # 我們直接呼叫自己的 list_projects，它會去問 WSL
        current_list = self.list_projects()
        
        # 2. 尋找目標專案 (優先匹配 UUID，兼容 Name)
        target = next((p for p in current_list if p.uuid == key), None)
        if not target:
            # Fallback: 試試看用名字找 (為了相容舊 UI 行為)
            target = next((p for p in current_list if p.name == key), None)
        
        if not target:
            print(f"Adapter: 找不到專案 {key}")
            return None

        # 3. 判斷意圖 & 發送指令
        # 根據我們在 list_projects 的定義：ui_status 為 "monitoring" 代表後端是 "running"
        try:
            if target.status == "monitoring":
                # 當前是監控中 -> 執行停止
                print(f"--- Adapter: Stopping sentry for {target.name} ({target.uuid}) ---")
                self._run_wsl_command("stop_sentry", target.uuid)
            else:
                # 當前是停止/失效 -> 執行啟動
                print(f"--- Adapter: Starting sentry for {target.name} ({target.uuid}) ---")
                self._run_wsl_command("start_sentry", target.uuid)
        except BackendError as e:
            # 如果後端報錯 (例如路徑不存在)，我們印出錯誤但不崩潰，讓 UI 顯示舊狀態或錯誤
            print(f"Adapter Error: {e}")
            return None

        # 4. 確認結果 (再撈一次，確保狀態已更新)
        # 給後端一點點時間處理 PID 檔案 (0.5秒通常足夠)
        import time
        time.sleep(1.5)
        
        new_list = self.list_projects()
        updated_target = next((p for p in new_list if p.uuid == target.uuid), None)
        
        return updated_target

    # 這裡，我們用「def」來定義（define）獲取忽略設定的函式。
    def get_ignore_settings(self) -> IgnoreSettings:
        # 直接回傳（return）初始化時設定的忽略設定物件（_ignore_settings）。
        return self._ignore_settings
    

    def add_project(self, name: str, path: str, output_file: str) -> None:
        """
        【真實化】呼叫 WSL daemon 新增專案。
        - 對應後端指令: add_project <name> <path> <output_file>
        """
        name = (name or "").strip()
        path = (path or "").strip()
        output_file = (output_file or "").strip()

        # 基本防呆
        if not name:
            raise BackendError("【新增失敗】：專案名稱不得為空。")
        if not path:
            raise BackendError("【新增失敗】：專案資料夾路徑不得為空。")
        if not output_file:
            raise BackendError("【新增失敗】：寫入檔路徑不得為空。")
        
        # [Task 9.4.3] 安全防呆：防止迴圈監控
        try:
            p_source = Path(path).resolve()
            p_target = Path(output_file).resolve()
            
            # --- [修正] 移除對一般專案的內部寫入限制 ---
            # 規則 A：一般專案允許 target 在 source 內 (後端有黑名單機制可防迴圈)
            # 只有在監控 Sentry 自身時才需要限制，但為了避免誤殺，這裡先放行。
            
            # 檢查 2: 禁止監控敏感系統目錄 (這部分保留)
            # 這裡增加對 .venv 的過濾，這也是常見誤區
            if p_source.name in ["logs", "temp", "data", ".venv"] or "projects.json" in str(p_source):
                raise BackendError("【安全攔截】禁止監控系統保留目錄或設定檔！")
            
        except Exception as e:
            if isinstance(e, BackendError):
                raise e
            print(f"[Warning] Path safety check failed: {e}")   

        # 呼叫通用通訊函式
        # 如果後端驗證失敗 (如路徑不存在、重名)，會拋出例外，被 UI 捕獲顯示紅字
        self._run_wsl_command("add_project", name, path, output_file)
        
        # 成功後不需要回傳值，UI 會自動重刷列表

# 這裡，我們用「def」來定義（define）刪除專案的函式。
    def delete_project(self, uuid: str) -> None:
        """呼叫 WSL 刪除專案。"""
        if not uuid:
            raise BackendError("刪除失敗：UUID 為空。")
        self._run_wsl_command("delete_project", uuid)

    # 這裡，我們用「def」來定義（define）修改專案的函式。
    def edit_project(self, uuid: str, field: str, new_value: str) -> None:
        """
        【真實化】發送 edit_project 指令給 WSL。
        - 對應後端指令: edit_project <uuid> <field> <new_value>
        """
        if not uuid or not field or not new_value:
            raise BackendError("編輯失敗：UUID、欄位名稱或新值不得為空。")
        
        # 呼叫通用通訊函式
        code, output = self._run_wsl_command("edit_project", uuid, field, new_value)

        # 這裡，我們用「def」來定義（define）追加目標的函式。
    def add_target(self, uuid: str, new_target: str) -> None:
        """呼叫 WSL 為專案追加寫入目標。"""
        if not uuid or not new_target:
            raise BackendError("追加失敗：參數不得為空。")
        self._run_wsl_command("add_target", uuid, new_target)

    # 這裡，我們用「def」來定義（define）移除目標的函式。
    def remove_target(self, uuid: str, target_to_remove: str) -> None:
        """呼叫 WSL 移除專案的寫入目標。"""
        if not uuid or not target_to_remove:
            raise BackendError("移除失敗：參數不得為空。")
        self._run_wsl_command("remove_target", uuid, target_to_remove)

    # 這裡，我們用「def」來定義（define）觸發手動更新的函式。
    def trigger_manual_update(self, uuid: str) -> None:
        """呼叫 WSL 執行一次手動更新。"""
        if not uuid:
            raise BackendError("更新失敗：UUID 為空。")
        self._run_wsl_command("manual_update", uuid)

    def save_tree_comment(self, uuid: str, path_key: str, comment: str) -> Dict[str, Any]:
        """呼叫 WSL 將單一節點註解同步回寫到 target markdown。"""
        if not uuid:
            raise BackendError("註解同步失敗：UUID 為空。")
        if path_key is None:
            raise BackendError("註解同步失敗：path_key 不得為空。")
        if comment is None:
            raise BackendError("註解同步失敗：comment 不得為空。")

        result = self._run_wsl_command("save_tree_comment", uuid, path_key, comment)

        if isinstance(result, dict):
            return result

        raise BackendError("註解同步失敗：後端未回傳合法 JSON 物件。")

    def publish_tree(self, uuid: str) -> Dict[str, Any]:
        """呼叫 WSL 以第一寫入檔為 SSOT，將 AUTO_TREE 區塊發布到後續寫入檔。"""
        if not uuid:
            raise BackendError("註解發佈失敗：UUID 為空。")

        result = self._run_wsl_command("publish_tree", uuid)

        if isinstance(result, dict):
            return result

        raise BackendError("註解發佈失敗：後端未回傳合法 JSON 物件。")


    # 這裡，我們用「def」來定義（define）獲取忽略候選名單的函式。
    def get_ignore_candidates(self, uuid: str) -> List[str]:
        """呼叫 WSL 獲取忽略規則候選名單（含現有規則 + 目錄）。"""
        if not uuid:
            return []
        
        # 呼叫後端指令：list_ignore_candidates <uuid>
        result = self._run_wsl_command("list_ignore_candidates", uuid)
        
        if isinstance(result, list):
            return [str(x) for x in result]
        return []
    
    def get_current_ignore_patterns(self, uuid: str) -> List[str]:
        """呼叫 WSL 獲取「目前已啟用」的忽略規則。"""
        if not uuid:
            return []
        
        # 呼叫剛才新增的後端指令
        result = self._run_wsl_command("list_ignore_patterns", uuid)
        
        if isinstance(result, list):
            return [str(x) for x in result]
        return []

    # 這裡，我們用「def」來定義（define）更新忽略規則的函式。
    def update_ignore_patterns(self, uuid: str, patterns: List[str]) -> None:
        """呼叫 WSL 更新忽略規則。"""
        if not uuid:
            raise BackendError("更新失敗：UUID 為空。")

        # 呼叫後端指令：update_ignore_patterns <uuid> <p1> <p2> ...
        # 我們將 patterns 列表展開 (*patterns) 作為參數傳遞
        self._run_wsl_command("update_ignore_patterns", uuid, *patterns)

        # 這裡，我們用「def」來定義（define）獲取日誌內容的函式。
    def get_log_content(self, uuid: str) -> List[str]:
        """呼叫 WSL 獲取指定專案的日誌內容。"""
        if not uuid:
            return []
        
        # 呼叫後端指令：get_log <uuid>
        result = self._run_wsl_command("get_log", uuid)
        
        if isinstance(result, list):
            return [str(x) for x in result]
        return []

    def get_project_tree(self, uuid: str) -> Dict[str, Any]:
        """呼叫 WSL 獲取指定專案的結構化目錄樹資料。"""
        if not uuid:
            raise BackendError("讀取目錄樹失敗：UUID 為空。")

        result = self._run_wsl_command("get_project_tree", uuid)

        if isinstance(result, dict):
            return result

        raise BackendError("讀取目錄樹失敗：後端未回傳合法 JSON 物件。")

    def preview_tree_from_path(self, path: str) -> Dict[str, Any]:
        """呼叫 WSL 取得臨時資料夾的結構化預覽樹資料。"""
        if not path:
            raise BackendError("臨時預覽失敗：path 不得為空。")

        result = self._run_wsl_command("preview_tree", path)

        if isinstance(result, dict):
            return result

        raise BackendError("臨時預覽失敗：後端未回傳合法 JSON 物件。")
    
    # [Task 9.4] 審計功能：獲取靜默路徑
    def get_muted_paths(self, uuid: str) -> List[str]:
        """呼叫 WSL 獲取該專案目前被靜默的路徑列表。"""
        if not uuid:
            return []
        
        # 對應後端指令: get_muted_paths <uuid>
        result = self._run_wsl_command("get_muted_paths", uuid)
        
        if isinstance(result, list):
            return [str(x) for x in result]
        return []

    # [Task 9.4] 審計功能：執行固化
    def solidify_ignore_patterns(self, uuid: str) -> None:
        """呼叫 WSL 將目前的靜默路徑「固化」進 ignore_patterns。"""
        if not uuid:
            raise BackendError("固化失敗：UUID 為空。")
            
        # 對應後端指令: add_ignore_patterns <uuid>
        # (注意：後端指令叫 add_ignore_patterns，但我們 UI 語意叫 solidify)
        self._run_wsl_command("add_ignore_patterns", uuid)

# ============================
#  模組層：給 tray_app 使用的單例介面
# ============================

# 單例 adapter（懶載入）
# 建立一個叫 _adapter_singleton 的變數，預設是空的（Optional[BackendAdapter] = None）。
# 之後整個應用程式只會建立這一個 Adapter 物件。
_adapter_singleton: Optional[BackendAdapter] = None


# 這裡，我們用「def」來定義（define）確保 Adapter 物件已經被建立的函式。
def _ensure_adapter() -> BackendAdapter:
    # 宣告（global）我們要修改這個全域變數 _adapter_singleton。
    global _adapter_singleton
    # 用「if」來判斷：如果（if）它已經被建立了（不是 None）...
    if _adapter_singleton is not None:
        # 就直接回傳（return）現有的物件。
        return _adapter_singleton

    # 【核心修改】我們不再需要這個高風險的 UNC 路徑了！
    # 傳入一個標示字串即可，BackendAdapter 現在是「指令發送器」，不是「檔案讀取器」。
    json_path = "WSL_MODE_NO_DIRECT_FILE_ACCESS"

    # 建立（instantiate）BackendAdapter 物件，把路徑傳入。
    _adapter_singleton = BackendAdapter(json_path)
    # 回傳（return）這個新建立的物件。
    return _adapter_singleton


# 這裡，我們用「def」來定義（define）對外提供的獲取專案列表函式。
def list_projects() -> List[ProjectInfo]:
    """
    tray_app 期待的介面：
    - 回傳 List[ProjectInfo]
    - ProjectInfo 內含 name/status/mode/path/output_file/target_files
    """
    # 呼叫（call）_ensure_adapter 函式，獲取 Adapter 物件。
    adapter = _ensure_adapter()
    # 呼叫（call）Adapter 內部的 list_projects 函式並回傳結果。
    return adapter.list_projects()


# 這裡，我們用「def」來定義（define）對外提供的切換專案狀態函式。
def toggle_project_status(key: str) -> Optional[ProjectInfo]:
    """
    tray_app 期待的介面：
    - key 可以是 uuid 或 name（過渡期）
    """
    # 呼叫（call）_ensure_adapter 函式，獲取 Adapter 物件。
    adp = _ensure_adapter()

    # 先試 uuid
    # 我們用「for...in...」這個結構，來一個一個地（for）檢查 Adapter 內部（_projects）。
    for raw in adp._projects:
        # 用「if」來判斷：如果（if）原始專案的 uuid 等於（==）傳入的 key...
        if raw.uuid == key:
            # 就呼叫（call）Adapter 內部的 toggle_project_status，並回傳（return）結果。
            # 這裡傳入的是 name，因為 Adapter 內部是以 name 來判斷的（過渡期邏輯）。
            return adp.toggle_project_status(raw.name)

    # 否則 fallback 成舊行為（靠 name）
    # 如果上面 for 循環沒有找到 uuid，就回到原本的行為：直接用 key（name）去切換狀態。
    return adp.toggle_project_status(key)


# 這裡，我們用「def」來定義（define）對外提供的獲取忽略設定函式。
def get_ignore_settings() -> IgnoreSettings:
    """
    tray_app 期待的介面：
    - 回傳 IgnoreSettings（sentry_ignore_patterns, tree_depth_limit）
    """
    # 呼叫（call）_ensure_adapter 函式，獲取 Adapter 物件。
    adapter = _ensure_adapter()
    # 呼叫（call）Adapter 內部的 get_ignore_settings 函式並回傳結果。
    return adapter.get_ignore_settings()

# 這裡，我們用「def」來定義（define）對外提供的新增專案函式（目前是 stub）。
def add_project(name: str, path: str, output_file: str) -> None:
    """
    tray_app 期待的介面（stub 版本）：

    - 目前只會呼叫 BackendAdapter.add_project(...)
    - add_project 內部只會做參數檢查 + print，不會改變 projects.json
    """
    # 呼叫（call）_ensure_adapter 函式，獲取 Adapter 物件。
    adapter = _ensure_adapter()
    # 呼叫（call）Adapter 內部的 add_project 函式。
    return adapter.add_project(name, path, output_file)

# 這裡，我們用「def」來定義（define）對外提供的刪除專案函式。
def delete_project(uuid: str) -> None:
    # 獲取（get）單例 adapter 並呼叫其 delete_project 方法。
    adapter = _ensure_adapter()
    return adapter.delete_project(uuid)

# 這裡，我們用「def」來定義（define）對外提供的修改專案函式。
def edit_project(uuid: str, field: str, new_value: str) -> None:
    # 獲取（get）單例 adapter 並呼叫其 edit_project 方法。
    adapter = _ensure_adapter()
    return adapter.edit_project(uuid, field, new_value)

# 這裡，我們用「def」來定義（define）對外提供的追加目標函式。
def add_target(uuid: str, new_target: str) -> None:
    adapter = _ensure_adapter()
    return adapter.add_target(uuid, new_target)

# 這裡，我們用「def」來定義（define）對外提供的移除目標函式。
def remove_target(uuid: str, target_to_remove: str) -> None:
    adapter = _ensure_adapter()
    return adapter.remove_target(uuid, target_to_remove)

# 這裡，我們用「def」來定義（define）對外提供的觸發手動更新函式。
def trigger_manual_update(uuid: str) -> None:
    # 獲取（get）單例 adapter 並呼叫其 trigger_manual_update 方法。
    adapter = _ensure_adapter()
    return adapter.trigger_manual_update(uuid)

def save_tree_comment(uuid: str, path_key: str, comment: str) -> Dict[str, Any]:
    # 獲取（get）單例 adapter 並呼叫其 save_tree_comment 方法。
    adapter = _ensure_adapter()
    return adapter.save_tree_comment(uuid, path_key, comment)

def publish_tree(uuid: str) -> Dict[str, Any]:
    # 獲取（get）單例 adapter 並呼叫其 publish_tree 方法。
    adapter = _ensure_adapter()
    return adapter.publish_tree(uuid)


# 這裡，我們用「def」來定義（define）對外提供的獲取忽略候選函式。
def get_ignore_candidates(uuid: str) -> List[str]:
    adapter = _ensure_adapter()
    return adapter.get_ignore_candidates(uuid)

def get_current_ignore_patterns(uuid: str) -> List[str]:
    adapter = _ensure_adapter()
    return adapter.get_current_ignore_patterns(uuid)

# 這裡，我們用「def」來定義（define）對外提供的更新忽略規則函式。
def update_ignore_patterns(uuid: str, patterns: List[str]) -> None:
    adapter = _ensure_adapter()
    return adapter.update_ignore_patterns(uuid, patterns)

# ============================
#  [v9.2.3 新增] 路徑比對邏輯 (把髒活藏在 Adapter)
# ============================

def _local_to_wsl_path(local_path: str) -> str:
    """
    [內部工具] 將 Windows 本地路徑轉換為 WSL 格式。
    """
    import re
    # 1. 統一轉為正斜線，去除頭尾空白
    p = local_path.strip().replace("\\", "/")
    
    # 2. 處理 WSL UNC 路徑 (例如 //wsl.localhost/Ubuntu/home/user/...)
    if p.startswith("//wsl") or p.startswith("//WSL"):
        parts = p.split("/")
        # 取第 4 個元素之後的部分
        if len(parts) >= 5:
            return "/" + "/".join(parts[4:])
    
    # 3. 處理 Windows 磁碟機 (例如 D:/Project) -> /mnt/d/Project
    match_drive = re.match(r"^([A-Za-z]):/(.*)", p)
    if match_drive:
        drive = match_drive.group(1).lower()
        rest = match_drive.group(2)
        return f"/mnt/{drive}/{rest}"
        
    return p.rstrip("/")

def match_project_by_path(local_path: str) -> Optional[ProjectInfo]:
    """
    [UI 專用] 給定一個 Windows 路徑，檢查是否為已註冊專案。
    如果是，回傳 ProjectInfo；如果不是，回傳 None。
    """
    # 1. 轉換路徑
    target_wsl_path = _local_to_wsl_path(local_path)
    
    # 2. 獲取專案列表 (這會觸發一次 WSL 呼叫，確保資料最新)
    # 如果怕太慢，也可以改用 _ensure_adapter()._projects (快取)，但這裡求穩先讀新的
    all_projects = list_projects()
    
    # 3. 比對 (忽略結尾斜線差異)
    target_clean = target_wsl_path.rstrip("/")
    
    for proj in all_projects:
        # 專案路徑也可能帶有斜線，統一清理
        proj_path_clean = proj.path.strip().replace("\\", "/").rstrip("/")
        
        if proj_path_clean == target_clean:
            return proj
            
    return 

# 這裡，我們用「def」來定義（define）對外提供的獲取日誌函式。
def get_log_content(uuid: str) -> List[str]:
    adapter = _ensure_adapter()
    return adapter.get_log_content(uuid)

def get_project_tree(uuid: str) -> Dict[str, Any]:
    adapter = _ensure_adapter()
    return adapter.get_project_tree(uuid)

def preview_tree_from_path(path: str) -> Dict[str, Any]:
    adapter = _ensure_adapter()
    return adapter.preview_tree_from_path(path)

# 這裡，我們用「def」來定義（define）對外提供的切換專案狀態函式。
def get_muted_paths(uuid: str) -> List[str]:
    adapter = _ensure_adapter()
    return adapter.get_muted_paths(uuid)

def solidify_ignore_patterns(uuid: str) -> None:
    adapter = _ensure_adapter()
    return adapter.solidify_ignore_patterns(uuid)

# ============================
# Demo（可直接 python -m src.backend.adapter）
# ============================

# 這裡，我們用「def」來定義（define）一個用於測試的示範（demo）函式。
def _demo() -> None:
    # 呼叫（call）_ensure_adapter 函式，獲取 Adapter 物件。
    adp = _ensure_adapter()

    # 用「print」輸出（output）標題。
    print("\n=== backend_adapter demo ===")
    print("目前專案列表：")
    
    # 我們用「for...in...」這個結構，來一個一個地（for）處理所有專案。
    for proj in adp.list_projects():
        # 用「print」格式化輸出每個專案的名稱、狀態和模式。
        # {proj.name:28s} 是指用 28 個字元來顯示 name，並靠左對齊。
        print(
            f"- {proj.name:28s} | status={proj.status:10s} | mode={proj.mode:11s}"
        )

    # 用「if」來判斷：如果（if）專案列表裡面有東西（不是空的）...
    if adp.list_projects():
        # 獲取（get）第一個專案的名稱。
        name = adp.list_projects()[0].name
        print(f"\n切換 {name} 狀態...")
        
        # 呼叫（call）toggle_project_status 函式來切換狀態。
        updated = adp.toggle_project_status(name)
        # 輸出切換後的專案資訊。
        print("切換後：", updated)

    # 輸出（output）目前的忽略設定。
    print("\n忽略設定：", adp.get_ignore_settings())


# 這是 Python 標準的寫法：如果（if）這個檔案是直接執行的主程式...
if __name__ == "__main__":
    # 就呼叫（call）_demo 函式來執行測試。
    _demo()