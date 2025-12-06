# 我們需要 導入（import）一系列 Python 內建的工具。
import os          # 用於與「作業系統（os）」互動。
import json        # 用於處理「JSON」格式的數據。
import portalocker # 我們最核心的「文件鎖（portalocker）」工具。
import tempfile # 用於創建安全的「臨時文件（tempfile）」。
from typing import Callable, Any, Tuple # 【v4.1 修正】補上被遺忘的 Tuple 類型。
# 用於提供更精確的「類型提示（typing）」。
import shutil      # 【v3.0 新增】導入一個更高級的「文件操作工具（shutil）」，用於安全地複製文件。
import sys
import time
import inspect
import copy  # 用於建立資料快照，防止原地修改導致比對失效
# SSOT: 導入路徑權威函式，取代內部的硬編碼計算
from .path import get_temp_dir, get_lists_dir, get_projects_temp_dir

# 【v3.0 新增】我們用「class」關鍵字，來定義一個我們自己的、專門用於「通知」的警告類型。
# 它繼承自 Python 內建的「Exception」，這意味著它可以像其他異常一樣被「try...except」捕獲。
class DataRestoredFromBackupWarning(Exception):
    """一個特殊的、非致命的警告，用於通知上層數據已從備份中恢復。"""
    pass


# +++ 這是最終的、絕對正確的、回滾所有錯誤微修的版本 +++
def safe_read_modify_write(
    file_path: str,
    update_callback: Callable[[Any], Any],
    serializer: str = 'json',
    max_backups: int = 3,
    project_uuid: str | None = None
) -> Tuple[Any, bool]:
    
# [DEBUG] 抓出是誰在寫 projects.json
    if "projects.json" in file_path:
        # 獲取呼叫者的函式名稱
        caller = inspect.stack()[1].function
        print(f"[IO_GATEWAY DEBUG] projects.json 被 {caller} 寫入！", file=sys.stderr)

# --- 1. 決定 temp 三大族譜中的實際落點 (SSOT) ---
    base_filename = os.path.basename(file_path)

    # 目前精準處理：
    if base_filename == "projects.json":
        # - projects.json → 進 lists 族譜 (由 path.py 統一管理)
        temp_dir = get_lists_dir()

    elif project_uuid:
        # - 若明確給了 project_uuid → 進 projects/<uuid>/ 族譜
        temp_dir = get_projects_temp_dir(str(project_uuid))

    elif "_" in base_filename and base_filename.split("_")[0].isalnum():
        # - 舊版兼容：從檔名推 uuid，例如 "<uuid>_xxx.bak"
        # COMPAT: 這是為了兼容尚未傳入 project_uuid 的舊流程
        project_id = base_filename.split("_")[0]
        temp_dir = get_projects_temp_dir(project_id)

    else:
        # - 其他（未分類）暫時落在 temp 根目錄
        temp_dir = get_temp_dir()

    # 在選好的 temp_dir 裡面放鎖檔
    lock_path = os.path.join(temp_dir, base_filename + ".lock")

    restored_from_backup = False
    temp_path = None

    try:
        with portalocker.Lock(lock_path, 'w', timeout=5):
            
            # --- 1. 讀取舊數據 (帶自愈功能) ---
            current_data = [] if serializer == 'json' else ""
            try:
                with open(file_path, 'r', encoding='utf-8') as f:
                    content = f.read()
                    if content:
                        # 我們只在 serializer 是 'json' 時才嘗試解析
                        if serializer == 'json':
                            current_data = json.loads(content)
                        else:
                            current_data = content
            except FileNotFoundError:
                pass 
            except json.JSONDecodeError:
                # 這裡的邏輯是正確的，它只會在解析 JSON 時觸發
                print(f"【I/O 網關警告】：檢測到 '{os.path.basename(file_path)}' 文件損壞，正在嘗試從備份恢復...", file=sys.stderr)
                # 我們先列出 temp/ 目錄下所有跟我們目標文件相關的備份。
                backup_files = [f for f in os.listdir(temp_dir) if f.startswith(base_filename) and f.endswith('.bak')]
                # 我們對找到的備份文件，按文件名（也就是時間戳）進行降序排序，這樣最新的就在最前面。
                backup_files.sort(reverse=True)

                # 我們逐一嘗試這些備份文件。
                for backup_filename in backup_files:
                    backup_path = os.path.join(temp_dir, backup_filename)
                    try:
                        shutil.copyfile(backup_path, file_path)
                        restored_from_backup = True
                        print(f"【I/O 網關通知】：已成功從備份 '{os.path.basename(backup_path)}' 恢復數據。", file=sys.stderr)
                        with open(file_path, 'r', encoding='utf-8') as f:
                            # 再次確保只在 JSON 模式下解析
                            if serializer == 'json':
                                current_data = json.loads(f.read())
                            else:
                                current_data = f.read()
                        break
                    except Exception as restore_e:
                        print(f"【I/O 網關錯誤】：從 '{os.path.basename(backup_path)}' 恢復失敗: {restore_e}", file=sys.stderr)
                        continue
                if not restored_from_backup:
                    raise IOError(f"目標文件 '{os.path.basename(file_path)}' 已損壞，且所有備份均無法恢復。")

            # [FIX] 建立快照：因為 update_callback 可能會原地修改 list/dict
            # 所以我們必須先備份一份「修改前」的樣子，才能正確比對差異。
            snapshot_data = copy.deepcopy(current_data)

            # [FIX] 建立快照：因為 update_callback 可能會原地修改 list/dict
            # 所以我們必須先備份一份「修改前」的樣子，才能正確比對差異。
            snapshot_data = copy.deepcopy(current_data)

            # --- 2. 調用回調函式 ---
            new_data = update_callback(current_data)

            # [FIX] 優化：只有在「數據真的變了」或者「剛執行過自癒」時，才寫入硬碟。
            # 這樣既能防止無限備份，又能確保自癒後的檔案會被保存。
            if new_data == snapshot_data and not restored_from_backup:
                return (new_data, restored_from_backup)

            # --- 3. 寫入臨時文件 (帶有 #2 和 #3 的正確微修) ---
            dir_path = os.path.dirname(file_path) or "."
            with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', newline='\n', dir=dir_path, delete=False) as tmp:
                temp_path = tmp.name
                if serializer == 'json':
                    json.dump(new_data, tmp, ensure_ascii=False, indent=2)
                    tmp.write("\n") 
                else:
                    tmp.write(str(new_data).rstrip() + "\n")
                tmp.flush()
                os.fsync(tmp.fileno())

            # --- 4. 創建備份 (v2.0 時間戳增強版) ---
            if os.path.exists(file_path):
                # 我們獲取當前時間，並格式化成一個適合做文件名的字串。
                timestamp = time.strftime("%Y%m%d-%H%M%S")
                # 我們構造出帶有時間戳的、位於 temp/lists/ 目錄下的新備份文件名。
                new_backup_path = os.path.join(temp_dir, f"{base_filename}.{timestamp}.bak")
                # 我們不再是「重命名」，而是安全地「複製」原始文件到備份區。
                shutil.copyfile(file_path, new_backup_path)

                # --- 【新增】自動清理舊備份 ---
                # 我們再次列出所有相關的備份文件（只看 temp/lists/ 裡的）。
                all_backups = [f for f in os.listdir(temp_dir) if f.startswith(base_filename) and f.endswith('.bak')]
                # 按文件名（時間戳）升序排序，這樣最舊的就在最前面。
                all_backups.sort()
                # 如果備份數量超過了我們的限制...
                if len(all_backups) > max_backups:
                    # 我們計算出需要刪除多少個最舊的備份。
                    backups_to_delete = all_backups[:len(all_backups) - max_backups]
                    # 逐一刪除它們。
                    for backup_to_delete in backups_to_delete:
                        os.remove(os.path.join(temp_dir, backup_to_delete))


            # --- 5. 原子替換 ---
            os.replace(temp_path, file_path)
            temp_path = None 
            
            return (new_data, restored_from_backup)

    except portalocker.LockException:
        raise IOError(f"無法獲取文件鎖...")
    # 【核心改造】我們在這裡，專門捕獲由回調函式拋出的、已知的業務邏輯異常。
    except ValueError as e:
        # 當捕獲到它們時，我們必須用 raise 將其原封不動地、再次向上拋出！
        raise e
    except Exception as e:
        # 只有對於未知的、意外的錯誤，我們才將其包裝成一個通用的 IOError。
        raise IOError(f"執行安全讀寫事務時發生未知錯誤: {e}")
    finally:
        if temp_path and os.path.exists(temp_path):
            os.remove(temp_path)
        if os.path.exists(lock_path):
            try:
                os.remove(lock_path)
            except OSError:
                pass