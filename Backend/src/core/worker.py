# ==============================================================================
# 工人專家 worker.py  （v2.0 - 純 Python 重生版）
#
# 職責：
#   - 取代舊版 worker.sh，負責執行一次「生產 → 包裝」的完整更新流水線。
#   - 與 engine.py 和 formatter.py 進行內部直接呼叫（不再經過 subprocess）。
#   - 提供 execute_update_workflow 作為 daemon.py 的唯一入口。
#
# 設計原則：
#   - 不持有任何全域狀態（stateless）。
#   - 不執行任何檔案 I/O（所有 I/O 由 daemon 或 io_gateway 處理）。
#   - 僅負責「純運算」：產生樹（engine）＋包裝文本（formatter）。
#
# TAG 類型：
#   - HACK: 為了環境相容性或歷史遺留因素的必要技巧。
#   - COMPAT: 為相容舊版腳本而暫時保留的接口。
# ==============================================================================


import os
import sys
from io import StringIO
from typing import Optional, Set

# ------------------------------------------------------------------------------
# HACK: 專案根目錄導入修正（僅在直接執行 worker.py 時使用）
#
# WHY：
#   - 允許工程師在終端直接執行：python worker.py ...
#   - 在被 daemon.py 呼叫時，不會走這段（package 已存在）
# ------------------------------------------------------------------------------
if __name__ == '__main__' and __package__ is None:
    current_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(os.path.dirname(current_dir))
    sys.path.insert(0, project_root)

# 工人專家僅依賴 engine（生產線）與 formatter（包裝線）
from src.core import engine, formatter


# ==============================================================================
# execute_update_workflow: 工人主流程（daemon 專用接口）
#
# 請注意：
#   - 工人不負責任何檔案讀寫（I/O），所有 I/O 已上移到 daemon.io_gateway。
#   - 工人只負責「計算」：產生樹狀圖 → 套用 formatter 包裝。
#
# 流程：
#   1. 調用 engine.generate_annotated_tree() 產生純內容（raw material）
#   2. 透過 fake_stdin / fake_stdout 技巧安全執行 formatter.main()
#   3. 回傳最終成品給 daemon，由 daemon 寫入檔案
#
# 回傳格式：
#   (exit_code: int, output: str)
#       exit_code = 0 → 成功
#       exit_code = 3 → 工人內部未知錯誤
# ==============================================================================
def execute_update_workflow(
    project_path: str,
    target_doc: str,
    old_content: str,
    ignore_patterns: Optional[Set[str]] = None
) -> tuple[int, str]:
    """
    【工人專家 v2.0 - 純 Python 版】
    執行完整的「生產 → 包裝」更新流水線。
    """
    try:
        # ----------------------------------------------------------------------
        # 步驟 1：生產線（engine）
        # ----------------------------------------------------------------------
        raw_material = engine.generate_annotated_tree(
            project_path,
            old_content,
            ignore_patterns=ignore_patterns
        )

        # ----------------------------------------------------------------------
        # 步驟 2：包裝線（formatter）
        #
        # 為了安全地呼叫 formatter.main()
        # 我們創建 fake_stdin + fake_stdout 模擬一個完整 CLI 執行環境。
        # ----------------------------------------------------------------------
        fake_stdin = StringIO(raw_material)
        fake_stdout = StringIO()
        fake_argv = ['formatter.py', '--strategy', 'obsidian']

        # 備份原本的系統 I/O 狀態
        original_stdin, original_stdout, original_argv = sys.stdin, sys.stdout, sys.argv

        try:
            sys.stdin, sys.stdout, sys.argv = fake_stdin, fake_stdout, fake_argv
            formatter.main()  # 在隔離環境內安全執行 formatter
            finished_product = fake_stdout.getvalue()
        finally:
            # 無論是否發生錯誤，均要確保 I/O 狀態恢復
            sys.stdin, sys.stdout, sys.argv = original_stdin, original_stdout, original_argv

        # 工人成功完成任務
        return (0, finished_product.strip())

    except Exception as e:
        # 全域防護：確保所有錯誤都具備可觀察性
        error_message = (
            "【工人失敗 v2.0】：在純 Python 工作流中發生意外錯誤。\n"
            f"--- 錯誤詳情 ---\n{type(e).__name__}: {e}"
        )
        return (3, error_message)


# ==============================================================================
# COMPAT：舊式 CLI 相容層
#
# WHY：
#   - 保留給尚未更新的舊測試或舊腳本使用。
#   - Daemon 不會再調用這段（新版已全面走 Python 內部流程）。
# ==============================================================================
if __name__ == '__main__':
    if len(sys.argv) != 3:
        print("用法: python worker.py <project_path> <target_doc>", file=sys.stderr)
        sys.exit(1)

    project_path_arg = sys.argv[1]
    target_doc_arg = sys.argv[2]
    old_content_arg = sys.stdin.read()

    exit_code, result = execute_update_workflow(project_path_arg, target_doc_arg, old_content_arg)

    if exit_code == 0:
        print(result)
    else:
        print(result, file=sys.stderr)

    sys.exit(exit_code)
