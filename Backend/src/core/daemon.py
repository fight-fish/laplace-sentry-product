# 導入（import）Python 內建的標準工具
import json
import uuid
import os
import sys
import time
import signal
import subprocess
import shutil
from typing import Optional, Tuple, List, Dict, Any

# 導入（import）專案內部的專家模組
# 1. 路徑專家：負責路徑計算與驗證
from .path import (normalize_path, validate_paths_exist, get_project_root, get_temp_dir, get_lists_dir, get_sentry_dir, get_projects_temp_dir)
# 2. 工人專家：負責執行更新
from .worker import execute_update_workflow
# 3 目錄樹專家：負責提供 UI 用的結構化樹資料
from .engine import generate_structured_tree
# 4. I/O 網關：負責安全讀寫與備份
from .io_gateway import safe_read_modify_write, DataRestoredFromBackupWarning


# --- 內部清理函式 ---

def _cleanup_project_temp_dir(project_uuid: str) -> None:
    """
    刪除單一專案的 temp/projects/<uuid>/ 目錄。
    """
    # SSOT: 單一權威來源。改為呼叫 path.py 函式，不再自行計算路徑。
    project_temp_path = get_projects_temp_dir(project_uuid)

    if os.path.isdir(project_temp_path):
        try:
            shutil.rmtree(project_temp_path)
            print(f"[INFO] 已清除暫存目錄: {project_temp_path}")
        except Exception as e:
            print(f"[警告] 刪除專案暫存資料夾失敗: {e}", file=sys.stderr)

def _cleanup_project_logs(project_config: Dict[str, Any]) -> None:
    """
    刪除單一專案在 logs/ 底下的 log 檔。
    """
    project_name = project_config.get("name", "Unnamed_Project")
    safe_prefix = "".join(c if c.isalnum() else "_" for c in project_name)

    # SSOT: 改為在函式內部呼叫 get_project_root() 來確保單一權威來源。
    log_dir = os.path.join(get_project_root(), "logs")
    log_file = os.path.join(log_dir, f"{safe_prefix}.log")

    if os.path.exists(log_file):
        try:
            os.remove(log_file)
            print(f"【守護進程】: 已刪除專案 log 檔案 -> {safe_prefix}.log")
        except OSError as e:
            print(f"【守護進程警告】：刪除 log 檔案 {safe_prefix}.log 時失敗: {e}", file=sys.stderr)


def is_self_project_path(path: str) -> bool:
    """
    # DEFENSE: 哨兵自我攻擊防護牆
    # 用途：判斷給定路徑是否位於 laplace_sentry_control_v2 專案內部。
    #      用來避免 output_file 指向系統目錄（如 logs/, temp/）引發監控迴圈。
    """
    abs_path = os.path.abspath(path)
    # SSOT: 改為在函式內部呼叫 get_project_root()
    root = get_project_root()

    # 統一補上結尾的分隔符，避免誤判
    if not root.endswith(os.sep):
        root = root + os.sep

    # 兩種情況都算「自己」：
    return abs_path == root or abs_path.startswith(root)


# --- 全局狀態管理 ---

# 用來記錄正在運行的哨兵進程 (PID)。
# Key: 專案 UUID, Value: subprocess.Popen 物件 (或 PidProxy)
running_sentries: Dict[str, Any] = {}

# 用來保管日誌檔案物件，防止被垃圾回收 (GC) 提早關閉。
# Key: 專案 UUID, Value: file object
sentry_log_files: Dict[str, Any] = {}


# --- 核心工具函式 ---

def get_projects_file_path(provided_path: Optional[str] = None) -> str:
    """
    # SSOT: 權威路徑來源
    # 用途：決定 projects.json 的真實位置。
    # 優先順序：1. 函式參數 (依賴注入) -> 2. 環境變數 (測試模式) -> 3. 預設生產路徑
    """
    # 1. 如果有直接傳入路徑，就直接使用。
    if provided_path:
        return provided_path
    
    # 2. 如果設定了測試環境變數，就使用測試路徑。
    if 'TEST_PROJECTS_FILE' in os.environ:
        return os.environ['TEST_PROJECTS_FILE']
    
    # 3. 否則，使用標準的生產環境路徑。
    # 我們呼叫 path.py 的權威函式來獲取根目錄。
    from .path import get_project_root
    return os.path.join(get_project_root(), 'data', 'projects.json')



# --- 數據庫輔助函式 ---

def read_projects_data(file_path: str) -> List[Dict[str, Any]]:
    """
    讀取專案列表。
    邏輯：將 I/O 操作完全委託給 io_gateway，並負責處理「數據恢復警告」。
    """
    try:
        # 定義一個唯讀的回調函式
        def read_only_callback(data):
            return data
        
        # 調用 I/O 網關，獲取數據與恢復標誌
        new_data, restored = safe_read_modify_write(file_path, read_only_callback, serializer='json')
        
        if restored:
            # 如果數據是從備份恢復的，向上層拋出警告信號
            raise DataRestoredFromBackupWarning("專案列表已從備份恢復，請檢查。")
            
        return new_data

    except DataRestoredFromBackupWarning:
        raise  # 讓信號繼續向上傳遞給 main_dispatcher
    except IOError as e:
        print(f"【守護進程警告】：讀取專案文件時出錯: {e}", file=sys.stderr)
        return []


def read_projects_data_readonly(file_path: str) -> List[Dict[str, Any]]:
    """
    純唯讀地讀取 projects.json。
    用途：提供給不允許產生任何寫入副作用的查詢型 API（例如 get_project_tree）。
    """
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()

        if not content.strip():
            return []

        data = json.loads(content)
        if isinstance(data, list):
            return data

        print("【守護進程警告】：projects.json 內容不是 list，已回傳空列表。", file=sys.stderr)
        return []

    except FileNotFoundError:
        return []
    except json.JSONDecodeError as e:
        raise IOError(f"唯讀解析專案文件失敗（JSON 損壞）: {e}")
    except OSError as e:
        raise IOError(f"唯讀讀取專案文件失敗: {e}")


def write_projects_data(data: List[Dict[str, Any]], file_path: str):
    """
    寫入專案列表。
    邏輯：將 I/O 操作完全委託給 io_gateway。
    """
    try:
        # 定義一個覆蓋寫入的回調函式
        def overwrite_callback(_):
            return data
        
        # 調用 I/O 網關（我們不關心回傳的數據，只關心是否成功執行）
        _, restored = safe_read_modify_write(file_path, overwrite_callback, serializer='json')
        
        if restored:
            raise DataRestoredFromBackupWarning("專案列表在寫入前檢測到損壞並已從備份恢復，請檢查。")

    except DataRestoredFromBackupWarning:
        raise
    except IOError as e:
        raise IOError(f"寫入專案文件時失敗: {e}")


def _get_targets_from_project(project_data: Dict[str, Any]) -> List[str]:
    """
    從專案配置中提取所有目標寫入檔案的路徑。
    兼容 'target_files' (List) 和舊版 'output_file' (Str/List) 欄位。
    """
    targets = project_data.get('target_files')
    if isinstance(targets, list) and targets: 
        return targets
    
    # 舊版兼容邏輯
    output = project_data.get('output_file')
    if isinstance(output, list) and output: 
        return output
    if isinstance(output, str) and output.strip(): 
        return [output]
    
    return []

# --- 統一更新入口 ---

def _run_single_update_workflow(project_path: str, target_doc: str, ignore_patterns: Optional[set] = None) -> Tuple[int, str]:
    """
    執行單次「讀取 -> 生成 -> 格式化」的更新流程。
    """
    if not isinstance(project_path, str) or not os.path.isdir(project_path):
        return (2, f"【更新失敗】: 專案路徑不存在或無效 -> {project_path}")
    if not isinstance(target_doc, str) or not target_doc.strip():
        return (1, "【更新失敗】: 目標文件路徑參數不合法。")
    if not os.path.isabs(target_doc):
        return (1, f"【更新失敗】: 目標文件需為絕對路徑 -> {target_doc}")

    timestamp = time.strftime('%Y-%m-%d %H:%M:%S')
    print(f"[{timestamp}] [Daemon] INFO: 收到更新請求。使用唯一的標準工人: worker.py", file=sys.stderr)

    try:
        with open(target_doc, 'r', encoding='utf-8') as f:
            old_content = f.read()
    except FileNotFoundError:
        old_content = ""
    except Exception as e:
        return (3, f"[DAEMON:READ] 讀取目標文件時發生意外錯誤: {e}")

    # 調用 worker 執行核心邏輯
    exit_code, result = execute_update_workflow(project_path, target_doc, old_content, ignore_patterns=ignore_patterns)

    timestamp_done = time.strftime('%Y-%m-%d %H:%M:%S')
    status = "成功" if exit_code == 0 else "失敗"
    print(f"[{timestamp_done}] [Daemon] INFO: 更新流程執行完畢。狀態: {status}", file=sys.stderr)
        
    return (exit_code, result)


# --- 靜默與忽略規則管理 (Ignore Patterns & Muting) ---

def _get_status_file_path(sentry_uuid: str) -> str:
    """
    回傳指定哨兵 UUID 的 .sentry_status 狀態檔路徑 (/tmp/<uuid>.sentry_status)。
    """
    return f"/tmp/{sentry_uuid}.sentry_status"

def handle_get_muted_paths(args: List[str]) -> List[str]:
    """
    【API】讀取指定哨兵目前的靜默路徑列表 (Muted Paths)。
    """
    if len(args) != 1:
        raise ValueError("handle_get_muted_paths 需要 1 個參數 (uuid)。")

    sentry_uuid = args[0]
    status_file = _get_status_file_path(sentry_uuid)

    if not os.path.exists(status_file):
        return []

    try:
        with open(status_file, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return []

    if not isinstance(data, list):
        return []

    return [p for p in data if isinstance(p, str)]

def _derive_ignore_patterns_from_muted_paths(muted_paths: List[str]) -> List[str]:
    """
    策略：將具體的靜默路徑轉化為通用的忽略規則。
    - 檔案 (含 .) -> 取父目錄名稱
    - 目錄 -> 取目錄名稱
    """
    patterns: set[str] = set()

    for raw in muted_paths:
        if not isinstance(raw, str): continue
        path = raw.strip()
        if not path: continue

        norm = os.path.normpath(path)
        parent, base = os.path.split(norm)

        if not base and parent:
            base = os.path.basename(parent)
        if not base: continue

        if "." in base and parent:
            target_name = os.path.basename(parent) or base
        else:
            target_name = base

        if target_name:
            patterns.add(target_name)

    return sorted(patterns)

def handle_add_ignore_patterns(args: List[str]) -> List[str]:
    """
    【API】將當前哨兵的靜默路徑，永久化為 projects.json 內的 ignore_patterns。
    流程：讀取狀態檔 -> 推導規則 -> 寫入設定 -> 清除狀態檔
    """
    if len(args) != 1:
        raise ValueError("handle_add_ignore_patterns 需要 1 個參數 (uuid)。")

    sentry_uuid = args[0]
    status_file = _get_status_file_path(sentry_uuid)

    # 1. 讀取
    if not os.path.exists(status_file): return []
    try:
        with open(status_file, "r", encoding="utf-8") as f:
            muted_paths = json.load(f)
    except Exception:
        muted_paths = []

    if not isinstance(muted_paths, list): muted_paths = []

    # 2. 推導
    patterns_to_add = _derive_ignore_patterns_from_muted_paths(muted_paths)

    if not patterns_to_add:
        try: os.remove(status_file)
        except OSError: pass
        return []

    # 3. 寫入 (Atomic Update)
    projects_file_path = get_projects_file_path()

    def _merge_ignore_patterns(projects: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        for project in projects:
            if project.get("uuid") == sentry_uuid:
                existing = project.get("ignore_patterns")
                current = {str(x) for x in existing if isinstance(x, str)} if isinstance(existing, list) else set()
                
                before = set(current)
                current.update(patterns_to_add)

                if current != before:
                    project["ignore_patterns"] = sorted(current)
                break
        return projects

    safe_read_modify_write(projects_file_path, _merge_ignore_patterns, serializer="json")

    # 4. 清理
    try: os.remove(status_file)
    except OSError: pass

    return patterns_to_add

SYSTEM_DEFAULT_IGNORE_NAMES = {".git", "__pycache__", ".venv", ".vscode"}

def list_ignore_patterns_for_project(uuid: str, projects_file_path: Optional[str] = None) -> List[str]:
    """列出專案目前已設定的忽略規則。"""
    PROJECTS_FILE = get_projects_file_path(projects_file_path)
    projects = read_projects_data(PROJECTS_FILE)
    project = next((p for p in projects if p.get("uuid") == uuid), None)
    if not project:
        raise ValueError(f"未找到具有該 UUID 的專案 '{uuid}'。")
    raw = project.get("ignore_patterns")
    if isinstance(raw, list):
        return sorted({str(x) for x in raw if isinstance(x, str)})
    return []

def list_ignore_candidates_for_project(uuid: str, projects_file_path: Optional[str] = None) -> List[str]:
    """列出專案目錄下的所有候選忽略項目 (第一層目錄 + 現有規則)。"""
    PROJECTS_FILE = get_projects_file_path(projects_file_path)
    projects = read_projects_data(PROJECTS_FILE)
    project = next((p for p in projects if p.get("uuid") == uuid), None)
    if not project:
        raise ValueError(f"未找到具有該 UUID 的專案 '{uuid}'。")

    candidates: set[str] = set()
    candidates.update(list_ignore_patterns_for_project(uuid, projects_file_path=projects_file_path))

    project_path = project.get("path")
    if isinstance(project_path, str) and os.path.isdir(project_path):
        try:
            for name in os.listdir(project_path):
                full = os.path.join(project_path, name)
                if os.path.isdir(full):
                    candidates.add(name)
        except OSError: pass

    candidates = {n for n in candidates if n not in SYSTEM_DEFAULT_IGNORE_NAMES}
    return sorted(candidates)

def update_ignore_patterns_for_project(uuid: str, new_patterns: List[str], projects_file_path: Optional[str] = None) -> None:
    """更新專案的 ignore_patterns 設定。"""
    PROJECTS_FILE = get_projects_file_path(projects_file_path)
    cleaned = sorted({str(x).strip() for x in new_patterns if str(x).strip()})

    def _update(projects: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        for p in projects:
            if p.get("uuid") == uuid:
                p["ignore_patterns"] = cleaned
                break
        else:
            raise ValueError(f"未找到具有該 UUID 的專案 '{uuid}'。")
        return projects

    safe_read_modify_write(PROJECTS_FILE, _update, serializer="json")


# --- 命令處理函式 (Command Handlers) ---

def handle_list_projects(projects_file_path: Optional[str] = None):
    """
    列出所有專案及其狀態。
    包含：
    1. 殭屍普查：清理無效的 PID 文件。
    2. 狀態同步：檢查 PID 存活、路徑有效性、靜默狀態。
    """
    # 1. 全國人口普查：清理名存實亡的「殭屍戶籍」
    sentry_dir = "Unknown" # [Fix] 預設值，防止報錯時變數未定義
    try:
        sentry_dir = get_sentry_dir()
        for filename in os.listdir(sentry_dir):
            if filename.endswith(".sentry"):
                pid_file_path = os.path.join(sentry_dir, filename)
                try:
                    pid = int(filename.split('.')[0])
                    
                    # 檢查 PID 是否真實存在
                    os.kill(pid, 0)
                    
                    # 若存活，檢查內存中是否有記錄
                    with open(pid_file_path, 'r', encoding='utf-8') as f:
                        sentry_uuid = f.read().strip()

                    if sentry_uuid and sentry_uuid not in running_sentries:
                        # 發現存活但失憶的哨兵，建立代理物件
                        class PidProxy:
                            def __init__(self, pid): self.pid = pid
                            def poll(self):
                                try:
                                    os.kill(self.pid, 0)
                                    return None
                                except ProcessLookupError:
                                    return 1
                            def kill(self):
                                try: os.kill(self.pid, 9)
                                except ProcessLookupError: pass

                        running_sentries[sentry_uuid] = PidProxy(pid)
                        print(f"【普查成功 DEBUG】發現存活哨兵: UUID={sentry_uuid}, PID={pid}", file=sys.stderr)

                except (ValueError, ProcessLookupError) as e:
                    print(f"【殭屍普查 DEBUG】：PID {pid} 被判定死亡 (Error: {e})，正在清理戶籍 {filename}...", file=sys.stderr)
                    try:
                        os.remove(pid_file_path)
                    except OSError as e:
                        print(f"【殭屍普查警告】：清理殭屍戶籍 {filename} 時失敗: {e}", file=sys.stderr)
                except Exception:
                    continue
    except OSError as e:
        print(f"【殭屍普查警告】：掃描戶籍登記處 ({sentry_dir}) 時發生 I/O 錯誤: {e}", file=sys.stderr)

    PROJECTS_FILE = get_projects_file_path(projects_file_path)
    projects_data = read_projects_data(PROJECTS_FILE)
    project_map = {p['uuid']: p for p in projects_data}

    # 初始化狀態
    for project in project_map.values():
        project['status'] = 'stopped'

    # 檢查路徑有效性
    for project in project_map.values():
        is_path_valid = os.path.isdir(project.get('path', ''))
        if not is_path_valid:
            project['status'] = 'invalid_path'

    # 檢查運行狀態
    sentry_uuids_to_check = list(running_sentries.keys())
    for uuid in sentry_uuids_to_check:
        process = running_sentries.get(uuid)
        if not process: continue

        project_config = project_map.get(uuid)
        is_alive = process.poll() is None
        is_path_valid_for_running = project_config and project_config.get('status') != 'invalid_path'

        if is_alive and is_path_valid_for_running:
            if uuid in project_map:
                project_map[uuid]['status'] = 'running'
                # print(f"【狀態更新 DEBUG】專案 {uuid} 已標記為 RUNNING", file=sys.stderr)
        else:
            print(f"【殭屍自愈】: 偵測到失效哨兵 (UUID: {uuid}, PID: {process.pid})。正在清理...", file=sys.stderr)
            try: process.kill()
            except Exception: pass
            finally:
                if uuid in running_sentries: del running_sentries[uuid]
                if uuid in project_map:
                    if not (project_config and os.path.isdir(project_config.get('path', ''))):
                        project_map[uuid]['status'] = 'invalid_path'

    # 檢查靜默狀態 (Muting)
    for project in project_map.values():
        uuid = project.get('uuid')
        if not uuid: continue
        
        status_file_path = f"/tmp/{uuid}.sentry_status"
        try:
            if os.path.exists(status_file_path):
                with open(status_file_path, 'r', encoding='utf-8') as f:
                    muted_paths = json.load(f)
                
                if isinstance(muted_paths, list) and len(muted_paths) > 0:
                    if project.get('status') != 'invalid_path':
                        project['status'] = 'muting'
        except (json.JSONDecodeError, IOError):
            continue

    return list(project_map.values())


def handle_add_project(args: List[str], projects_file_path: Optional[str] = None):
    """新增專案。"""
    PROJECTS_FILE = get_projects_file_path(projects_file_path)

    if len(args) != 3:
        raise ValueError("【新增失敗】：參數數量不正確，需要 3 個。")
    
    name, path, output_file = args
    clean_path = normalize_path(path)
    clean_output_file = normalize_path(output_file)

    if not os.path.isabs(clean_path) or not os.path.isabs(clean_output_file):
        raise ValueError("【新增失敗】：所有路徑都必須是絕對路徑。")
    
    parent_dir = os.path.dirname(clean_output_file)
    if parent_dir and not os.path.isdir(parent_dir):
        raise IOError(f"【新增失敗】：目標文件所在的資料夾不存在 -> {parent_dir}")

    if not os.path.isfile(clean_output_file):
        raise IOError(f"【新增失敗】：目標文件不存在 -> {clean_output_file}\n(請先在檔案總管建立該檔案，再進行註冊)")

    if not validate_paths_exist([clean_path]):
        raise IOError(f"【新增失敗】：專案目錄路徑不存在 -> {clean_path}")

    def add_callback(projects_data):
        if any(p.get('name') == name for p in projects_data):
            raise ValueError(f"專案別名 '{name}' 已被佔用。")
        if any(normalize_path(p.get('path', '')) == clean_path for p in projects_data):
            raise ValueError(f"專案路徑 '{clean_path}' 已被其他專案監控。")
        for p in projects_data:
            if any(normalize_path(target) == clean_output_file for target in _get_targets_from_project(p)):
                raise ValueError(f"目標文件 '{clean_output_file}' 已被專案 '{p.get('name')}' 使用。")
                    
        abs_out = os.path.abspath(clean_output_file)

        # 防護：禁止寫入哨兵自身專案
        if is_self_project_path(abs_out):
            raise ValueError(
                f"【新增失敗】: output_file 指向哨兵自身專案路徑\n"
                f"  ↳ 專案根目錄: {get_project_root()}\n"
                f"  ↳ 寫入路徑: {abs_out}\n"
                f"為避免哨兵監控並改寫自身系統檔案，已拒絕加入專案。"
            )

        new_project = {
            "uuid": str(uuid.uuid4()), "name": name, "path": clean_path,
            "output_file": [clean_output_file], "target_files": [clean_output_file],
        }
        projects_data.append(new_project)
        return projects_data

    safe_read_modify_write(PROJECTS_FILE, add_callback, serializer='json')


def handle_edit_project(args: List[str], projects_file_path: Optional[str] = None):
    """編輯專案屬性 (name, path, output_file)。"""
    PROJECTS_FILE = get_projects_file_path(projects_file_path)
    if len(args) != 3:
        raise ValueError("【編輯失敗】：參數數量不正確。")
    
    uuid_to_edit, field, new_value = args
    allowed_fields = ['name', 'path', 'output_file']
    if field not in allowed_fields:
        raise ValueError(f"無效的欄位名稱 '{field}'。")

    def edit_callback(projects_data):
        project_to_edit = next((p for p in projects_data if p.get('uuid') == uuid_to_edit), None)
        if project_to_edit is None:
            raise ValueError(f"未找到具有該 UUID 的專案 '{uuid_to_edit}'。")
        
        other_projects = [p for p in projects_data if p.get('uuid') != uuid_to_edit]
        
        if field == 'name':
            if any(p.get('name') == new_value for p in other_projects):
                raise ValueError(f"新的專案別名 '{new_value}' 已被佔用。")
            project_to_edit['name'] = new_value
        elif field == 'path':
            clean_new_path = normalize_path(new_value)
            if not os.path.isabs(clean_new_path) or not validate_paths_exist([clean_new_path]):
                raise ValueError(f"新的路徑無效或不存在 -> {clean_new_path}")
            if any(normalize_path(p.get('path', '')) == clean_new_path for p in other_projects):
                raise ValueError(f"新的專案路徑 '{clean_new_path}' 已被其他專案監控。")
            project_to_edit['path'] = clean_new_path
        elif field == 'output_file':
            clean_new_output_file = normalize_path(new_value)
            if not os.path.isabs(clean_new_output_file):
                raise ValueError("新的目標文件路徑必須是絕對路徑。")
            if not os.path.isfile(clean_new_output_file):
                raise ValueError(f"目標文件不存在 -> {clean_new_output_file}")
            
            abs_new_out = os.path.abspath(clean_new_output_file)

            if is_self_project_path(abs_new_out):
                raise ValueError(
                    f"【編輯失敗】: output_file 指向哨兵自身專案路徑\n"
                    f"  ↳ 哨兵專案根目錄: {get_project_root()}\n"
                    f"  ↳ 寫入路徑: {abs_new_out}\n"
                    f"為避免哨兵監控並改寫自身系統檔案，已拒絕修改。"
                )

            for p in other_projects:
                if any(normalize_path(target) == clean_new_output_file for target in _get_targets_from_project(p)):
                    raise ValueError(f"目標文件 '{clean_new_output_file}' 已被專案 '{p.get('name')}' 使用。")
            project_to_edit['output_file'] = [clean_new_output_file]
            project_to_edit['target_files'] = [clean_new_output_file]
            
        return projects_data

    safe_read_modify_write(PROJECTS_FILE, edit_callback, serializer='json')

    # 自動熱重啟 (Hot Reload)
    if uuid_to_edit in running_sentries:
        print(f"【系統自動調整】：偵測到專案配置變更，正在重啟哨兵以套用新設定...")
        time.sleep(0.5)
        handle_stop_sentry([uuid_to_edit], projects_file_path=projects_file_path)
        handle_start_sentry([uuid_to_edit], projects_file_path=projects_file_path)

def handle_add_target(args: List[str], projects_file_path: Optional[str] = None):
    """【API】為指定專案「追加」一個新的目標寫入檔"""
    PROJECTS_FILE = get_projects_file_path(projects_file_path)
    
    if len(args) != 2:
        raise ValueError("【追加失敗】：需要 2 個參數 (uuid, new_target_path)。")
    
    uuid_to_edit, new_target = args
    clean_target = normalize_path(new_target)

    if not os.path.isabs(clean_target):
        raise ValueError("目標路徑必須是絕對路徑。")
    
    abs_new = os.path.abspath(clean_target)
    if is_self_project_path(abs_new):
        raise ValueError("禁止將目標設定為哨兵自身專案路徑（避免監控迴圈）。")

    parent_dir = os.path.dirname(clean_target)
    if parent_dir and not os.path.isdir(parent_dir):
        raise IOError(f"【追加失敗】：目標文件所在的資料夾不存在 -> {parent_dir}")

    def add_callback(projects_data):
        project = next((p for p in projects_data if p.get('uuid') == uuid_to_edit), None)
        if not project:
            raise ValueError(f"找不到專案 {uuid_to_edit}")
        
        raw_targets = _get_targets_from_project(project)
        current_targets: List[str] = list(raw_targets)

        if any(normalize_path(t) == clean_target for t in current_targets):
            raise ValueError("該目標路徑已存在於此專案中。")

        other_projects = [p for p in projects_data if p.get('uuid') != uuid_to_edit]
        for p in other_projects:
            if any(normalize_path(t) == clean_target for t in _get_targets_from_project(p)):
                raise ValueError(f"路徑 '{clean_target}' 已被專案 '{p.get('name')}' 佔用。")

        current_targets.append(clean_target)
        project['output_file'] = current_targets
        project['target_files'] = current_targets
        return projects_data

    safe_read_modify_write(PROJECTS_FILE, add_callback, serializer='json')
    
    if uuid_to_edit in running_sentries:
        print(f"【系統自動調整】：偵測到目標變更，正在重啟哨兵以更新黑名單...")
        time.sleep(0.5)
        handle_stop_sentry([uuid_to_edit], projects_file_path=projects_file_path)
        handle_start_sentry([uuid_to_edit], projects_file_path=projects_file_path)

def handle_remove_target(args: List[str], projects_file_path: Optional[str] = None):
    """【API】從指定專案「移除」一個目標寫入檔"""
    PROJECTS_FILE = get_projects_file_path(projects_file_path)
    
    if len(args) != 2:
        raise ValueError("【移除失敗】：需要 2 個參數 (uuid, target_path_to_remove)。")

    uuid_to_edit, target_to_remove = args
    clean_remove = normalize_path(target_to_remove)

    def remove_callback(projects_data):
        project = next((p for p in projects_data if p.get('uuid') == uuid_to_edit), None)
        if not project:
            raise ValueError(f"找不到專案 {uuid_to_edit}")

        current_targets = _get_targets_from_project(project)
        new_targets = [t for t in current_targets if normalize_path(t) != clean_remove]

        if len(new_targets) == len(current_targets):
            raise ValueError(f"在專案中找不到目標路徑: {clean_remove}")
        
        if len(new_targets) < 1:
            raise ValueError("專案至少必須保留一個輸出目標，無法清空。")

        project['output_file'] = new_targets
        project['target_files'] = new_targets
        return projects_data

    safe_read_modify_write(PROJECTS_FILE, remove_callback, serializer='json')

    if uuid_to_edit in running_sentries:
        print(f"【系統自動調整】：偵測到目標變更，正在重啟哨兵...")
        time.sleep(0.5)
        handle_stop_sentry([uuid_to_edit], projects_file_path=projects_file_path)
        handle_start_sentry([uuid_to_edit], projects_file_path=projects_file_path)

def handle_delete_project(args: List[str], projects_file_path: Optional[str] = None):
    """
    刪除專案 (級聯清理)。
    順序：從 DB 移除 -> 停止哨兵 -> 清理 temp -> 清理 logs
    """
    PROJECTS_FILE = get_projects_file_path(projects_file_path)

    if len(args) != 1:
        raise ValueError("【刪除失敗】：需要 1 個參數 (uuid)。")
    uuid_to_delete = args[0]

    deleted_project_config: Optional[Dict[str, Any]] = None

    def delete_callback(projects_data):
        nonlocal deleted_project_config
        deleted_project_config = next((p for p in projects_data if p.get('uuid') == uuid_to_delete), None)
        if deleted_project_config is None:
            raise ValueError(f"未找到具有該 UUID 的專案 '{uuid_to_delete}'。")
        return [p for p in projects_data if p.get('uuid') != uuid_to_delete]

    safe_read_modify_write(PROJECTS_FILE, delete_callback, serializer='json')

    if deleted_project_config is None: return

    try:
        handle_stop_sentry([uuid_to_delete])
    except Exception as e:
        print(f"【刪除專案警告】：停止專案哨兵時出現問題：{e}", file=sys.stderr)

    _cleanup_project_temp_dir(uuid_to_delete)
    _cleanup_project_logs(deleted_project_config)


def handle_manual_update(args: List[str], projects_file_path: Optional[str] = None):
    """手動觸發專案更新（對所有目標檔）。"""
    PROJECTS_FILE = get_projects_file_path(projects_file_path)

    if len(args) != 1:
        raise ValueError("【手動更新失敗】：需要 1 個參數 (uuid)。")
    uuid_to_update = args[0]

    projects_data = read_projects_data(PROJECTS_FILE)
    selected_project = next((p for p in projects_data if p.get('uuid') == uuid_to_update), None)
    
    if not selected_project:
        raise ValueError(f"未找到具有該 UUID 的專案 '{uuid_to_update}'。")

    project_path = selected_project.get('path')
    targets = _get_targets_from_project(selected_project)
    ignore_list = selected_project.get("ignore_patterns")
    ignore_patterns = set(ignore_list) if isinstance(ignore_list, list) else None

    if not project_path or not targets:
        raise ValueError(f"專案 '{selected_project.get('name')}' 缺少有效的路徑配置。")

    # 對每一個目標檔都執行更新
    for target_doc_path in targets:
        if not isinstance(target_doc_path, str) or not target_doc_path.strip():
            raise ValueError(f"專案 '{selected_project.get('name')}' 中存在無效的目標檔設定。")

        exit_code, formatted_tree_block = _run_single_update_workflow(
            project_path, target_doc_path, ignore_patterns=ignore_patterns
        )
        
        if exit_code != 0:
            raise RuntimeError(f"底層工人執行失敗（目標檔: {target_doc_path}）:\n{formatted_tree_block}")

        def update_md_callback(full_old_content):
            start_marker = "<!-- AUTO_TREE_START -->"
            end_marker = "<!-- AUTO_TREE_END -->"
            if start_marker in full_old_content and end_marker in full_old_content:
                head = full_old_content.split(start_marker)[0]
                tail = full_old_content.split(end_marker, 1)[1]
                return f"{head}{start_marker}\n{formatted_tree_block.strip()}\n{end_marker}{tail}"
            else:
                return (f"{full_old_content.rstrip()}\n\n{start_marker}\n{formatted_tree_block.strip()}\n{end_marker}").lstrip()

        safe_read_modify_write(
            target_doc_path,
            update_md_callback,
            serializer='text',
            project_uuid=uuid_to_update,
        )


def handle_manual_direct(args: List[str], ignore_patterns: Optional[set] = None, projects_file_path: Optional[str] = None):
    """
    自由模式更新：不依賴 projects.json，直接指定來源與目標。
    """
    if len(args) != 2:
        raise ValueError("【自由更新失敗】：需要 2 個參數 (project_path, target_doc_path)。")
    
    project_path, target_doc_path = map(normalize_path, args)

    if not os.path.isdir(project_path):
        raise IOError(f"專案目錄不存在或無效 -> {project_path}")
    if not os.path.isfile(target_doc_path):
        raise IOError(f"目標文件不存在 -> {target_doc_path}")

    exit_code, formatted_tree_block = _run_single_update_workflow(project_path, target_doc_path, ignore_patterns=ignore_patterns)
    if exit_code != 0:
        raise RuntimeError(f"底層工人執行失敗:\n{formatted_tree_block}")

    def update_md_callback(full_old_content):
        start_marker = "<!-- AUTO_TREE_START -->"
        end_marker = "<!-- AUTO_TREE_END -->"
        if start_marker in full_old_content and end_marker in full_old_content:
            head = full_old_content.split(start_marker)[0]
            tail = full_old_content.split(end_marker, 1)[1]
            return f"{head}{start_marker}\n{formatted_tree_block.strip()}\n{end_marker}{tail}"
        else:
            return f"{full_old_content.rstrip()}\n\n{start_marker}\n{formatted_tree_block.strip()}\n{end_marker}".lstrip()

    safe_read_modify_write(target_doc_path, update_md_callback, serializer='text')

def handle_start_sentry(args: List[str], projects_file_path: Optional[str] = None):
    """啟動指定專案的哨兵進程 (Background Sentry Worker)。"""
    PROJECTS_FILE = get_projects_file_path(projects_file_path)

    if len(args) != 1:
        raise ValueError("【啟動失敗】：需要 1 個參數 (uuid)。")
    uuid_to_start = args[0]

    if uuid_to_start in running_sentries:
        raise ValueError(f"專案的哨兵已經在運行中。")

    projects_data = read_projects_data(PROJECTS_FILE)
    project_config = next((p for p in projects_data if p.get('uuid') == uuid_to_start), None)

    if not project_config:
        raise ValueError(f"未找到具有該 UUID 的專案 '{uuid_to_start}'。")

    project_name = project_config.get("name", "Unnamed_Project")
    
    # 準備日誌路徑
    safe_name = "".join(c if c.isalnum() else "_" for c in project_name)
    log_filename = f"{safe_name}.log"
    log_dir = os.path.join(get_project_root(), 'logs') 
    log_file_path = os.path.join(log_dir, log_filename)
    os.makedirs(log_dir, exist_ok=True)

    # 準備命令
    sentry_script_path = os.path.join(get_project_root(), 'src', 'core', 'sentry_worker.py')
    python_executable = sys.executable
    project_path = project_config.get('path', '')

    # 啟動前檢查
    if not project_path or not os.path.isdir(project_path):
        raise IOError(f"【啟動失敗】: 專案 '{project_name}' 的監控路徑無效或不存在 -> {project_path}")

    command = [python_executable, "-u", sentry_script_path, uuid_to_start, project_path]

    # OUTPUT-FILE-BLACKLIST: 傳遞所有輸出檔路徑給哨兵，防止監控迴圈
    # 【BUG FIX】使用權威函式獲取目標，確保與 manual_update 寫入的檔案完全一致
    targets = _get_targets_from_project(project_config)
    output_files_str = ','.join(targets) if targets else ''
    command.append(output_files_str)

    try:    
        log_file = open(log_file_path, 'a', encoding='utf-8')

        print(f"【守護進程】: 正在為專案 '{project_name}' 啟動哨兵...")
        print(f"【守護進程】: 命令: {' '.join(command)}")
        print(f"【守護進程】: 日誌將被寫入: {log_file_path}")

        sentry_env = os.environ.copy()
        sentry_env["PYTHONIOENCODING"] = "utf-8"
        sentry_env["PYTHONUTF8"] = "1"

        # start_new_session=True: 脫離父進程 Session，避免被連帶終止
        process = subprocess.Popen(
            command, 
            stdout=log_file, 
            stderr=log_file, 
            text=True, 
            env=sentry_env, 
            start_new_session=True
        )
        
        pid = process.pid
        pid_file_path = os.path.join(get_sentry_dir(), f"{pid}.sentry")
        
        try:
            with open(pid_file_path, 'w', encoding='utf-8') as f:
                f.write(uuid_to_start)
        except IOError as e:
            print(f"【守護進程致命錯誤】：為 PID {pid} 創建戶籍文件失敗: {e}", file=sys.stderr)
            process.kill()
            raise RuntimeError(f"創建哨兵戶籍文件 {pid_file_path} 失敗。")

        # 登記到記憶體 (防止 GC 關閉 log_file)
        sentry_log_files[uuid_to_start] = log_file
        running_sentries[uuid_to_start] = process

        print(f"【守護進程】: 哨兵已成功啟動。進程 PID: {process.pid}")

        # 啟動後立即觸發一次更新 (確保黑名單生效)
        print(f"【守護進程】: 正在執行啟動後的初始更新...", file=sys.stderr)
        handle_manual_update([uuid_to_start], projects_file_path=projects_file_path)

    except Exception as e:
        raise RuntimeError(f"啟動哨兵子進程時發生致命錯誤: {e}")

def handle_stop_sentry(args: List[str], projects_file_path: Optional[str] = None):
    """停止指定專案的哨兵 (基於戶籍檔案)。"""
    if len(args) != 1:
        raise ValueError("【停止失敗】：需要 1 個參數 (uuid)。")
    uuid_to_stop = args[0]

    pid_to_kill = None
    pid_file_to_remove = None
    
    sentry_dir = get_sentry_dir() 

    # 1. 查找戶籍文件
    try:
        for filename in os.listdir(sentry_dir):
            if filename.endswith(".sentry"):
                pid_file_path = os.path.join(sentry_dir, filename)
                try:
                    with open(pid_file_path, 'r', encoding='utf-8') as f:
                        file_content_uuid = f.read().strip()
                    
                    if file_content_uuid == uuid_to_stop:
                        pid_to_kill = int(filename.split('.')[0])
                        pid_file_to_remove = pid_file_path
                        break
                except (IOError, ValueError):
                    print(f"【守護進程警告】：掃描戶籍文件 {pid_file_path} 時出錯，已跳過。", file=sys.stderr)
                    continue
    except OSError as e:
        raise IOError(f"【停止失敗】：掃描戶籍登記處 ({sentry_dir}) 時發生 I/O 錯誤: {e}")

    # 2. 如果找不到戶籍，檢查內存 (兼容舊模式)
    if pid_to_kill is None:
        if uuid_to_stop in running_sentries:
            print(f"【守護進程警告】：在內存中找到哨兵 {uuid_to_stop}，但未找到其戶籍文件。將嘗試按舊方式停止。", file=sys.stderr)
            process_to_stop = running_sentries.pop(uuid_to_stop)
            try: process_to_stop.kill()
            except Exception: pass
            raise ValueError(f"專案的哨兵可能處於異常狀態，已嘗試強制清理。")
        else:
            raise ValueError(f"未找到正在運行的、屬於專案 {uuid_to_stop} 的哨兵。")

    # 3. 終止進程
    print(f"【守護進程】: 正在嘗試停止哨兵 (PID: {pid_to_kill})...")
    try:
        import signal
        os.kill(pid_to_kill, signal.SIGTERM)
        print(f"【守護進程】: 哨兵 (PID: {pid_to_kill}) 已成功發送終止信號。")
    except ProcessLookupError:
        print(f"【守護進程】: 哨兵 (PID: {pid_to_kill}) 在嘗試停止前就已不存在。")
    except Exception as e:
        raise RuntimeError(f"停止哨兵 (PID: {pid_to_kill}) 時發生致命錯誤: {e}")
    finally:
        # 4. 清理現場
        if pid_file_to_remove and os.path.exists(pid_file_to_remove):
            try:
                os.remove(pid_file_to_remove)
                print(f"【守護進程】: 已成功註銷戶籍文件 {os.path.basename(pid_file_to_remove)}。")
            except OSError as e:
                print(f"【守護進程警告】：刪除戶籍文件 {pid_file_to_remove} 時失敗: {e}", file=sys.stderr)
        
        if uuid_to_stop in running_sentries:
            del running_sentries[uuid_to_stop]
            
        if uuid_to_stop in sentry_log_files:
            try: sentry_log_files[uuid_to_stop].close()
            except Exception: pass
            del sentry_log_files[uuid_to_stop]

def handle_get_project_tree(args: List[str], projects_file_path: Optional[str] = None) -> Dict[str, Any]:
    """
    【API】依專案 UUID 取得結構化目錄樹資料。
    只回傳 JSON 樹資料，不寫入 Markdown、不產生副作用。
    """
    PROJECTS_FILE = get_projects_file_path(projects_file_path)

    if len(args) != 1:
        raise ValueError("【讀取目錄樹失敗】：需要 1 個參數 (uuid)。")

    uuid_target = args[0]
    projects_data = read_projects_data_readonly(PROJECTS_FILE)
    selected_project = next((p for p in projects_data if p.get('uuid') == uuid_target), None)

    if not selected_project:
        raise ValueError(f"未找到具有該 UUID 的專案 '{uuid_target}'。")

    project_path = selected_project.get('path')
    targets = _get_targets_from_project(selected_project)
    ignore_list = selected_project.get("ignore_patterns")
    ignore_patterns = set(ignore_list) if isinstance(ignore_list, list) else None

    if not project_path or not os.path.isdir(project_path):
        raise ValueError(f"專案 '{selected_project.get('name')}' 的路徑不存在或無效。")

    old_content = ""
    if targets:
        first_target = targets[0]
        if isinstance(first_target, str) and first_target.strip() and os.path.isfile(first_target):
            try:
                with open(first_target, 'r', encoding='utf-8') as f:
                    old_content = f.read()
            except Exception:
                old_content = ""

    tree_data = generate_structured_tree(
        project_path,
        old_content_string=old_content,
        ignore_patterns=ignore_patterns,
    )

    return {
        "uuid": uuid_target,
        "project_name": selected_project.get("name", "Unnamed_Project"),
        "project_path": project_path,
        "tree": tree_data,
    }


def _get_primary_target_markdown(project_config: Dict[str, Any]) -> str:
    """
    取得單點註解回寫的固定 target markdown。
    S-02-02b v1 階段：固定採用專案的第一個 target。
    """
    targets = _get_targets_from_project(project_config)
    if not targets:
        raise RuntimeError("找不到可用的 target markdown。")

    target_doc = targets[0]
    if not isinstance(target_doc, str) or not target_doc.strip():
        raise RuntimeError("target markdown 設定無效。")

    target_doc = normalize_path(target_doc)
    if not os.path.isfile(target_doc):
        raise IOError(f"target markdown 不存在或不可讀取 -> {target_doc}")

    return target_doc


def _split_tree_line_comment(line: str) -> Tuple[str, Optional[str]]:
    """
    將樹節點行拆成：
    - base_part：不含 comment 的前半段
    - comment：註解內容（若無則為 None）
    """
    marker = " # "
    if marker in line:
        base_part, comment = line.split(marker, 1)
        return base_part, comment
    return line, None


def _resolve_path_key_from_tree_lines(lines: List[str], target_path_key: str) -> Optional[int]:
    """
    解析 AUTO_TREE 文字區塊中的每一行，找出指定 path_key 對應的行索引。
    規則：
    - 根節點 path_key = ""
    - 子節點 path_key = 相對專案根目錄的唯一路徑
    """
    import re

    stack: List[str] = []

    for index, raw_line in enumerate(lines):
        stripped = raw_line.strip()

        if not stripped:
            continue
        if stripped == "```":
            continue

        base_part, _ = _split_tree_line_comment(raw_line)
        base_rstrip = base_part.rstrip()

        match = re.match(
            r"^(?P<indent>(?:│   |    )*)(?P<branch>[├└]── )?(?P<name>.+?)\s*$",
            base_rstrip,
        )
        if not match:
            continue

        indent = match.group("indent") or ""
        branch = match.group("branch")
        name = (match.group("name") or "").rstrip()
        if not name:
            continue

        depth = len(indent) // 4
        if branch:
            depth += 1

        normalized_name = name[:-1] if name.endswith("/") else name

        stack = stack[:depth]
        stack.append(normalized_name)

        current_path_key = ""
        if depth > 0:
            current_path_key = "/".join(stack[1:])

        normalized_target = "" if target_path_key in ("", "(root)") else target_path_key
        if current_path_key == normalized_target:
            return index

    return None


def handle_save_tree_comment(args: List[str], projects_file_path: Optional[str] = None) -> Dict[str, Any]:
    """
    【API】單點更新指定 TreeNode 的 comment。
    規則：
    - 只更新 target markdown 既有 AUTO_TREE 區塊中的單一節點註解
    - 不觸發 manual_update
    - 不重建整個專案樹
    """
    PROJECTS_FILE = get_projects_file_path(projects_file_path)

    if len(args) != 3:
        raise ValueError("save_tree_comment 需要 3 個參數：<uuid> <path_key> <comment>")

    uuid_target, path_key, comment = args

    projects_data = read_projects_data(PROJECTS_FILE)
    selected_project = next((p for p in projects_data if p.get("uuid") == uuid_target), None)
    if not selected_project:
        raise ValueError(f"未找到具有該 UUID 的專案 '{uuid_target}'。")

    target_doc = _get_primary_target_markdown(selected_project)
    updated_comment = str(comment)

    def update_comment_callback(full_old_content: Any) -> str:
        if not isinstance(full_old_content, str):
            full_old_content = str(full_old_content or "")

        start_marker = "<!-- AUTO_TREE_START -->"
        end_marker = "<!-- AUTO_TREE_END -->"

        start_idx = full_old_content.find(start_marker)
        end_idx = full_old_content.find(end_marker)

        if start_idx == -1 or end_idx == -1 or end_idx < start_idx:
            raise RuntimeError("target markdown 缺少有效的 AUTO_TREE 區塊。")

        block_start = start_idx + len(start_marker)
        tree_block = full_old_content[block_start:end_idx]

        lines = tree_block.splitlines()
        target_line_index = _resolve_path_key_from_tree_lines(lines, path_key)
        if target_line_index is None:
            raise ValueError(f"找不到 path_key 對應節點：{path_key}")

        original_line = lines[target_line_index]
        base_part, _ = _split_tree_line_comment(original_line)
        new_line = base_part.rstrip()

        if updated_comment.strip():
            new_line = f"{new_line}  # {updated_comment}"

        lines[target_line_index] = new_line
        new_tree_block = "\n".join(lines)

        return f"{full_old_content[:block_start]}{new_tree_block}{full_old_content[end_idx:]}"

    safe_read_modify_write(
        target_doc,
        update_comment_callback,
        serializer="text",
        project_uuid=uuid_target,
    )

    return {
        "ok": True,
        "uuid": uuid_target,
        "path_key": path_key,
        "comment": updated_comment,
    }


def handle_get_log(args: List[str], projects_file_path: Optional[str] = None) -> List[str]:
    """【API】讀取日誌 (Tail)。"""
    PROJECTS_FILE = get_projects_file_path(projects_file_path)

    if len(args) < 1:
        raise ValueError("【讀取失敗】：需要至少 1 個參數 (uuid)。")
    
    uuid_target = args[0]
    try:
        limit = int(args[1]) if len(args) > 1 else 50
    except ValueError:
        limit = 50

    projects_data = read_projects_data(PROJECTS_FILE)
    project_config = next((p for p in projects_data if p.get('uuid') == uuid_target), None)

    if not project_config:
        return [f"錯誤：找不到 UUID 為 {uuid_target} 的專案。"]

    project_name = project_config.get("name", "Unnamed_Project")
    safe_name = "".join(c if c.isalnum() else "_" for c in project_name)
    log_filename = f"{safe_name}.log"
    # SSOT: 改為在函式內部呼叫 get_project_root()
    log_path = os.path.join(get_project_root(), 'logs', log_filename)

    if not os.path.exists(log_path):
        return ["(目前沒有日誌檔案，哨兵可能尚未啟動過)"]

    try:
        with open(log_path, 'r', encoding='utf-8', errors='replace') as f:
            lines = f.readlines()
            return [line.rstrip() for line in lines[-limit:]]
    except Exception as e:
        return [f"讀取日誌時發生錯誤：{e}"]

# --- 總調度中心 (Main Dispatcher) ---

def main_dispatcher(argv: List[str], **kwargs):
    """
    核心指令調度器。
    職責：接收 CLI 參數，解析後分派給對應的 handle_xxx 函式。
    """
    if not argv:
        print("錯誤：未提供任何命令。", file=sys.stderr)
        return 1

    command = argv[0]
    args = argv[1:]

    # 依賴注入：優先從 kwargs 獲取路徑設定（用於測試隔離）
    projects_file_path = kwargs.get('projects_file_path')

    try:
        # 根據指令分派任務
        if command == 'ping':
            print("PONG")

        elif command == 'list_projects':
            projects = handle_list_projects(projects_file_path=projects_file_path)
            print(json.dumps(projects, indent=2, ensure_ascii=False))

        elif command == 'add_project':
            handle_add_project(args, projects_file_path=projects_file_path)
            print("OK")

        elif command == 'edit_project':
            handle_edit_project(args, projects_file_path=projects_file_path)
            print("OK")

        elif command == 'add_target':
            handle_add_target(args, projects_file_path=projects_file_path)
            print("OK")

        elif command == 'remove_target':
            handle_remove_target(args, projects_file_path=projects_file_path)
            print("OK")

        elif command == 'delete_project':
            handle_delete_project(args, projects_file_path=projects_file_path)
            print("OK")

        elif command == 'manual_update':
            handle_manual_update(args, projects_file_path=projects_file_path)
            print("OK")

        elif command == 'manual_direct':
            handle_manual_direct(args, projects_file_path=projects_file_path)
            print("OK")

        elif command == 'start_sentry':
            handle_start_sentry(args, projects_file_path=projects_file_path)
            print("OK")

        elif command == 'stop_sentry':
            handle_stop_sentry(args, projects_file_path=projects_file_path)
            print("OK")

        elif command == "get_muted_paths":
            if not args:
                print("錯誤：缺少 UUID 參數。", file=sys.stderr)
                return 1
            uuid = args[0]
            result = handle_get_muted_paths([uuid])
            print(json.dumps(result, ensure_ascii=False, indent=2))

        elif command == "add_ignore_patterns":
            if not args:
                print("錯誤：缺少 UUID 參數。", file=sys.stderr)
                return 1
            uuid = args[0]
            result = handle_add_ignore_patterns([uuid])
            print(json.dumps(result, ensure_ascii=False, indent=2))

        elif command == 'list_ignore_candidates':
            if not args:
                print("錯誤：缺少 UUID 參數。", file=sys.stderr)
                return 1
            uuid = args[0]
            candidates = list_ignore_candidates_for_project(uuid, projects_file_path=projects_file_path)
            print(json.dumps(candidates, ensure_ascii=False, indent=2))

        elif command == 'list_ignore_patterns':
            if not args:
                print("錯誤：缺少 UUID 參數。", file=sys.stderr)
                return 1
            uuid = args[0]
            patterns = list_ignore_patterns_for_project(uuid, projects_file_path=projects_file_path)
            print(json.dumps(patterns, ensure_ascii=False, indent=2))

        elif command == 'update_ignore_patterns':
            if not args:
                print("錯誤：缺少 UUID 參數。", file=sys.stderr)
                return 1
            uuid = args[0]
            new_patterns = args[1:]
            
            # 1. 更新設定
            update_ignore_patterns_for_project(uuid, new_patterns, projects_file_path=projects_file_path)
            print("OK")

            # 2. 熱重啟檢查：解決 Stateless 架構下的狀態同步問題
            is_sentry_active = False
            try:
                # SSOT: 使用權威路徑檢查戶籍
                sentry_dir = get_sentry_dir()
                if os.path.exists(sentry_dir):
                    for fname in os.listdir(sentry_dir):
                        if fname.endswith('.sentry'):
                            try:
                                with open(os.path.join(sentry_dir, fname), 'r', encoding='utf-8') as f:
                                    if f.read().strip() == uuid:
                                        is_sentry_active = True
                                        break
                            except: continue
            except Exception as e:
                print(f"【系統警告】檢查哨兵狀態時發生錯誤: {e}", file=sys.stderr)

            # 如果哨兵活著，強制重啟以套用新規則
            if is_sentry_active:
                print(f"【系統自動調整】：偵測到忽略規則變更且哨兵運行中，執行熱重啟...", file=sys.stderr)
                time.sleep(0.5)
                try:
                    handle_stop_sentry([uuid], projects_file_path=projects_file_path)
                    handle_start_sentry([uuid], projects_file_path=projects_file_path)
                except Exception as e:
                    print(f"【熱重啟失敗】：{e}", file=sys.stderr)

        elif command == 'get_log':
            if not args:
                print("錯誤：缺少 UUID 參數。", file=sys.stderr)
                return 1
            result = handle_get_log(args, projects_file_path=projects_file_path)
            print(json.dumps(result, ensure_ascii=False, indent=2))

        elif command == 'get_project_tree':
            if not args:
                print("錯誤：缺少 UUID 參數。", file=sys.stderr)
                return 1
            result = handle_get_project_tree(args, projects_file_path=projects_file_path)
            print(json.dumps(result, ensure_ascii=False, indent=2))

        elif command == "save_tree_comment":
            if len(args) != 3:
                print("錯誤：save_tree_comment 需要 3 個參數：<uuid> <path_key> <comment>", file=sys.stderr)
                return 1

            try:
                result = handle_save_tree_comment(args, projects_file_path=projects_file_path)
                print(json.dumps(result, ensure_ascii=False, indent=2))
            except ValueError as e:
                message = str(e)
                print(message, file=sys.stderr)

                if "未找到具有該 UUID" in message:
                    return 2
                if "找不到 path_key 對應節點" in message:
                    return 3
                return 1
            except RuntimeError as e:
                print(str(e), file=sys.stderr)
                return 4
            except IOError as e:
                print(str(e), file=sys.stderr)
                return 5

        else:
            print(f"錯誤：未知命令 '{command}'。", file=sys.stderr)
            return 1
        
        return 0

    # 全局錯誤捕獲 (Global Error Handling)
    except DataRestoredFromBackupWarning:
        # 这是一个軟性警告，提示用戶重試
        print(f"【系統通知】偵測到設定檔損壞，已從備份自動恢復。請重新操作。", file=sys.stderr)
        return 10

    except (ValueError, IOError, RuntimeError) as e:
        # 測試模式下，向上拋出異常以便測試框架捕獲
        if 'LAPLACE_TEST_MODE' in os.environ:
            raise e
        # 生產模式下，印出錯誤訊息並返回錯誤碼 1
        print(str(e), file=sys.stderr)
        return 1

    except Exception as e:
        # 未知錯誤，返回錯誤碼 99
        print(f"【守護進程發生未知致命錯誤】：{e}", file=sys.stderr)
        return 99


# --- 主執行入口 ---
# --- 主執行入口 ---
if __name__ == "__main__":
    exit_code = main_dispatcher(sys.argv[1:])

    if exit_code is None:
        sys.exit(0)

    if isinstance(exit_code, bool):
        print("main_dispatcher must return int, not bool", file=sys.stderr)
        sys.exit(99)

    try:
        sys.exit(int(exit_code))
    except Exception:
        print(f"invalid exit code: {exit_code!r}", file=sys.stderr)
        sys.exit(99)