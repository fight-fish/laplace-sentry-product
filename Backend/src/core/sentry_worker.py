# sentry_worker.py (v11.2 - 完全體：鐵肺 + 完整大腦 R1-R4 + 風格合規版)
# 導入（import）sys 模組。
import sys
# 導入（import）time 模組。
import time
# 導入（import）os 模組。
import os
# 導入（import）signal 模組。
import signal
# 導入（import）json 模組。
import json
# 導入（import）subprocess 模組。
import subprocess
# 從 typing 導入（import）型別提示工具。
from typing import Set, Dict, List, Tuple
# 從 datetime 導入（import）時間處理工具。
from datetime import datetime, timedelta

# --------------------------------------------------------------------------
# 1. 基礎配置
# --------------------------------------------------------------------------
# 如果（if）作業系統是 Windows...
if sys.platform == 'win32':
    # 導入（import）io 模組。
    import io
    # 嘗試（try）設定標準輸出編碼。
    try:
        # 重設（sys.stdout）為 UTF-8 編碼。
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
        # 重設（sys.stderr）為 UTF-8 編碼。
        sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8')
    # 忽略（except）任何錯誤。
    except Exception:
        pass

# 設定（signal）忽略 SIGINT 信號。
signal.signal(signal.SIGINT, signal.SIG_IGN)

# 定義（define）內部忽略名單。
SENTRY_INTERNAL_IGNORE = (
    '.sentry_status', 'temp', 'README.md', 'logs', 'data',
    '.git', '__pycache__', '.venv', '.vscode', 'crash_report.txt', 'fault.log'
)

# 2. 計算專案根目錄
# 獲取（dirname）當前檔案的絕對路徑。
current_dir = os.path.dirname(os.path.abspath(__file__))
# 獲取（dirname）上一層目錄，定位到專案根目錄。
project_root = os.path.dirname(os.path.dirname(current_dir))

def trigger_update_cli(uuid):
    main_script = os.path.join(project_root, "main.py")
    cmd = [sys.executable, main_script, "manual_update", uuid]
    try:
        # 捕捉 stdout 和 stderr
        result = subprocess.run(cmd, cwd=project_root, check=True, capture_output=True, text=True, encoding='utf-8')
        print(f">>> 成功觸發更新指令", flush=True)
    except subprocess.CalledProcessError as e:
        # 【關鍵】印出 stderr，讓我們知道 main.py 為什麼死掉
        print(f"!!! 更新指令執行失敗: {e}", flush=True)
        print(f"!!! 錯誤詳情 (STDERR): {e.stderr}", flush=True)  
        print(f"!!! 錯誤詳情 (STDOUT): {e.stdout}", flush=True)  
    except Exception as e:
        print(f"!!! 呼叫 CLI 時發生錯誤: {e}", flush=True)

# 3. 智能大腦 (SmartThrottler - 完整版回歸)
# 我們定義（class）智能節流器類別。
class SmartThrottler:
    # 我們定義（def）初始化函式。
    def __init__(self,
                burst_creation_threshold: int = 20,
                burst_creation_period_seconds: float = 10.0,
                size_growth_threshold_mb: int = 100,
                size_growth_period_seconds: float = 60.0):
        
        # 設定（set）R1 單檔過熱閾值。
        self.hot_threshold = 5
        # 設定（set）R1 時間區間。
        self.hot_period = timedelta(seconds=5.0)
        # 初始化（init）熱點事件字典。
        self.hot_events: Dict[str, List[datetime]] = {}
        
        # 設定（set）R3 爆量閾值。
        self.burst_threshold = burst_creation_threshold
        # 設定（set）R3 時間區間。
        self.burst_period = timedelta(seconds=burst_creation_period_seconds)
        # 初始化（init）目錄事件字典。
        self.dir_events: Dict[str, List[datetime]] = {}

        # 設定（set）R4 體積閾值（Bytes）。
        self.size_threshold_bytes = size_growth_threshold_mb * 1024 * 1024
        # 設定（set）R4 時間區間。
        self.size_period = timedelta(seconds=size_growth_period_seconds)
        # 初始化（init）檔案大小歷史字典。
        self.file_sizes: Dict[str, List[Tuple[datetime, int]]] = {}

        # 初始化（init）靜默路徑集合。
        self.muted_paths: Set[str] = set()

    # 我們定義（def）判斷是否應該處理事件的函式。
    def should_process(self, event) -> bool:
        # 獲取（get）事件路徑。
        path = event.src_path
        # 如果（if）路徑或其父目錄在靜默名單中...
        if path in self.muted_paths or os.path.dirname(path) in self.muted_paths:
            # 返回（return）False，拒絕處理。
            return False

        # 獲取（get）當前時間。
        now = datetime.now()
        
        # --- R3: 爆量創建檢查 ---
        # 如果（if）是創建事件...
        if event.event_type == 'created':
            # 獲取（dirname）父目錄。
            parent_dir = os.path.dirname(path)
            # 獲取（get）該目錄的歷史事件。
            events = self.dir_events.get(parent_dir, [])
            # 過濾（filter）出時間區間內的有效事件。
            valid = [t for t in events if now - t < self.burst_period]
            # 加入（append）當前時間。
            valid.append(now)
            # 更新（update）字典。
            self.dir_events[parent_dir] = valid
            
            # 如果（if）超過閾值...
            if len(valid) > self.burst_threshold:
                # 輸出（print）靜默警告。
                print(f"[{now.strftime('%Y-%m-%d %H:%M:%S')}] 🔥 [智能靜默] 爆量創建 (R3): {os.path.basename(parent_dir)}", flush=True)
                # 加入（add）靜默名單。
                self.muted_paths.add(parent_dir)
                # 清除（pop）事件記錄。
                self.dir_events.pop(parent_dir, None)
                # 返回（return）False。
                return False

        # --- R1: 單檔過熱檢查 ---
        # 如果（if）是修改事件...
        if event.event_type == 'modified':
            # 獲取（get）該檔案的歷史事件。
            timestamps = self.hot_events.get(path, [])
            # 過濾（filter）有效事件。
            valid = [t for t in timestamps if now - t < self.hot_period]
            # 加入（append）當前時間。
            valid.append(now)
            # 更新（update）字典。
            self.hot_events[path] = valid
            
            # 如果（if）超過閾值...
            if len(valid) >= self.hot_threshold:
                # 輸出（print）靜默警告。
                print(f"[{now.strftime('%Y-%m-%d %H:%M:%S')}] 🔥 [智能靜默] 文件過熱 (R1): {os.path.basename(path)}", flush=True)
                self.muted_paths.add(path)
                # 清除（pop）事件記錄。
                self.hot_events.pop(path, None)
                # 返回（return）False。
                return False

        # --- R4: 體積異常檢查 ---
        # 如果（if）是修改事件且帶有大小資訊...
        if event.event_type == 'modified' and hasattr(event, 'file_size'):
            # 獲取（get）當前大小。
            current_size = event.file_size
            # 獲取（get）歷史記錄。
            history = self.file_sizes.get(path, [])
            # 過濾（filter）有效歷史。
            valid_history = [(t, s) for t, s in history if now - t < self.size_period]
            
            # 如果（if）有歷史記錄...
            if valid_history:
                # 取出（get）最早的大小。
                _, old_size = valid_history[0]
                # 計算（calc）增長量。
                growth = current_size - old_size
                # 如果（if）增長超過閾值...
                if growth > self.size_threshold_bytes:
                    # 輸出（print）靜默警告。
                    print(f"[{now.strftime('%Y-%m-%d %H:%M:%S')}] 🔥 [智能靜默] 體積異常 (R4): {os.path.basename(path)} (+{growth/1024/1024:.2f}MB)", flush=True)
                    # 加入（add）靜默名單。
                    self.muted_paths.add(path)
                    # 清除（pop）記錄。
                    self.file_sizes.pop(path, None)
                    # 返回（return）False。
                    return False
            
            # 加入（append）當前記錄。
            valid_history.append((now, current_size))
            # 更新（update）字典。
            self.file_sizes[path] = valid_history

        # 返回（return）True，允許處理。
        return True

# 我們定義（class）模擬事件類別。
class MockEvent:
    # 我們定義（def）初始化函式。
    def __init__(self, src_path, event_type='modified', file_size=0):
        self.src_path = src_path
        self.event_type = event_type
        self.is_directory = False
        self.file_size = file_size

# 4. 鐵肺核心 (FileSnapshot v2 - 支援大小)
# 我們定義（class）檔案快照類別。
class FileSnapshot:
    # 我們定義（def）初始化函式。
    def __init__(self, path: str):
        # 初始化（init）檔案字典：路徑 -> (mtime, size)。
        self.files: Dict[str, Tuple[float, int]] = {}
        # 執行（scan）掃描。
        self.scan(path)

    # 我們定義（def）掃描函式。
    def scan(self, root_path: str):
        # 使用（walk）遍歷目錄。
        for root, dirs, files in os.walk(root_path):
            # 過濾（filter）忽略的目錄。
            dirs[:] = [d for d in dirs if d not in SENTRY_INTERNAL_IGNORE]
            # 遍歷（loop）檔案。
            for file in files:
                # 如果（if）檔案在忽略名單中...
                if file in SENTRY_INTERNAL_IGNORE: continue
                # 組合（join）完整路徑。
                full_path = os.path.join(root, file)
                # 嘗試（try）獲取檔案狀態。
                try:
                    # 呼叫（stat）獲取狀態。
                    stat = os.stat(full_path)
                    # 儲存（save）修改時間和大小。
                    self.files[full_path] = (stat.st_mtime, stat.st_size)
                # 忽略（except）錯誤。
                except OSError: pass

# 5. 主入口
# 我們定義（def）主函式。
def main():
    # 如果（if）參數不足...
    if len(sys.argv) < 3:
        # 退出（exit）。
        sys.exit(1)

    # 獲取（get）專案 UUID。
    project_uuid = sys.argv[1]
    # 獲取（get）專案路徑。
    project_path = sys.argv[2]
    
    # 初始化（init）輸出檔案列表。
    output_files = []
    # 如果（if）有提供輸出檔案參數...
    if len(sys.argv) > 3:
        # 解析（split）逗號分隔的字串。
        output_files = [p.strip() for p in sys.argv[3].split(',') if p.strip()]
    # 轉為（set）集合以加速查詢。
    output_file_set = set(output_files)

    # 獲取啟動時間
    now = datetime.now()
    ts = now.strftime('%Y-%m-%d %H:%M:%S')

    # 輸出（print）啟動訊息 (加上時間)
    print(f"[{ts}] 哨兵啟動 (v11.2 完全體)。PID: {os.getpid()}", flush=True)
    
    # --- 補回黑名單日誌 ---
    if output_files:
        print(f"[{ts}] 【OUTPUT-FILE-BLACKLIST】已加載 {len(output_files)} 個輸出文件到黑名單", flush=True)
        # [探針] 印出黑名單的真實面貌
        for f in output_files:
            print(f"   🔒 黑名單項目 (repr): {repr(f)}", flush=True)
    else:
        print(f"[{ts}] 【OUTPUT-FILE-BLACKLIST】未接收到任何輸出文件黑名單", flush=True)
    # --------------------
    
    # 初始化（init）智能節流器。
    throttler = SmartThrottler()
    # 初始化（init）上一次的靜默狀態。
    last_muted_state: Set[str] = set()

    # 我們定義（def）更新狀態檔的函式。
    def update_status_file():
        # 宣告（nonlocal）使用外部變數。
        nonlocal last_muted_state
        # 獲取（get）當前靜默名單。
        current_muted = throttler.muted_paths
        # 如果（if）狀態有變動...
        if current_muted != last_muted_state:
            # 定義（define）狀態檔路徑。
            status_file = f"/tmp/{project_uuid}.sentry_status"
            # 嘗試（try）寫入檔案。
            try:
                # 開啟（open）檔案。
                with open(status_file, 'w', encoding='utf-8') as f:
                    # 寫入（dump）JSON。
                    json.dump(list(current_muted), f)
                # 更新（update）緩存狀態。
                last_muted_state = current_muted.copy()
            # 忽略（except）錯誤。
            except:
                pass

    # 輸出（print）建立快照訊息。
    print(f"[{ts}] [Step] 建立初始快照...", flush=True)
    # 建立（create）初始快照。
    last_snapshot = FileSnapshot(project_path)
    # 輸出（print）監控中訊息。
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] [Step] 監控中 (Files: {len(last_snapshot.files)})", flush=True)

    # 嘗試（try）進入主迴圈。
    try:
        # 無窮迴圈（while True）。
        while True:
            # 休眠（sleep）2 秒。
            time.sleep(2)
            
            # 建立（create）當前快照。
            current_snapshot = FileSnapshot(project_path)
            # 初始化（init）有效變動標記。
            any_effective_change = False
            
            # 1. 檢查變動 (新增/修改)
            # 遍歷（loop）當前快照中的檔案。
            for path, info in current_snapshot.files.items():
                # 如果（if）是輸出檔案，跳過（continue）。
                if path in output_file_set: continue
                
                # 解構（unpack）資訊。
                mtime, size = info
                # 獲取（get）舊資訊。
                old_info = last_snapshot.files.get(path)
                
                # 如果（if）舊資訊不存在（新增）...
                if old_info is None:
                    # [修正後的探針位置] 只有真的發現新增時才印
                    if path.endswith(".txt"):
                        print(f"   🔎 [新增] 發現 .txt: {path}", flush=True)
                        print(f"   ❓ 是否在黑名單中: {path in output_file_set}", flush=True)

                    evt = MockEvent(path, 'created', size)
                    if throttler.should_process(evt):
                        # 輸出（print）偵測訊息。
                        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [偵測] created: {os.path.basename(path)}", flush=True)
                        # 標記（mark）為有效變動。
                        any_effective_change = True
                
                # 否則（elif），如果時間或大小變了（修改）...
                elif mtime > old_info[0] or size != old_info[1]:
                    # [修正後的探針位置] 只有真的發現修改時才印
                    if path.endswith(".txt"):
                        print(f"   🔎 [修改] 發現 .txt 變動: {path}", flush=True)
                        print(f"   ❓ 是否在黑名單中: {path in output_file_set}", flush=True)

                    evt = MockEvent(path, 'modified', size)
                    # 如果（if）通過大腦審查...
                    if throttler.should_process(evt): 
                        # 輸出（print）偵測訊息。
                        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [偵測] modified: {os.path.basename(path)}", flush=True)
                        # 標記（mark）為有效變動。
                        any_effective_change = True
            
            # 2. 檢查刪除
            # 遍歷（loop）舊快照中的檔案。
            for path in last_snapshot.files:
                # 如果（if）不在當前快照中（被刪除）...
                if path not in current_snapshot.files:
                    # 如果（if）不是輸出檔案...
                    if path not in output_file_set:
                        # 輸出（print）偵測訊息。
                        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [偵測] deleted: {os.path.basename(path)}", flush=True)
                        # 標記（mark）為有效變動。
                        any_effective_change = True

            # 更新（update）狀態檔。
            update_status_file()
            
            # 如果（if）有有效變動...
            if any_effective_change:
                # 觸發（trigger）更新指令。
                trigger_update_cli(project_uuid)
            
            # 如果（if）快照有變化...
            if current_snapshot.files != last_snapshot.files:
                # 更新（update）基準快照。
                last_snapshot = current_snapshot

    # 捕獲（except）中斷信號。
    except KeyboardInterrupt:
        pass
    # 捕獲（except）所有其他異常。
    except Exception as e:
        # 輸出（print）崩潰訊息。
        print(f"哨兵崩潰: {e}", file=sys.stderr)

# 如果（if）直接執行此腳本...
if __name__ == "__main__":
    # 執行（call）主函式。
    main()