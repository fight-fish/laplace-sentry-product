# ==============================================================================
# 模組職責：engine.py
# - 負責生成「目錄樹」的純文字結構，並與註釋資訊進行合併。
# - 提供給 daemon / worker 調用的核心 API：generate_annotated_tree()。
# - 不直接做任何檔案 I/O，相同輸入必須產生相同輸出（pure function）。
#
# 已知歷史與風險：
# - 早期版本曾因相對路徑計算錯誤，導致註釋靜默丟失（參考相關日誌）。
# - 現版本透過「路徑 key」模型與系統級忽略名單，盡量降低結構變動帶來的風險。
# ==============================================================================

# 我們需要導入（import）幾個 Python 內建的標準工具：
import os       # 用於與「作業系統（os）」互動，例如遍歷目錄、檢查檔案型態。
import sys      # 用於讀取命令列參數，並在 CLI 模式下輸出錯誤訊息或設定退出碼。
import re       # 用於執行必要的「正規表達式（re）」匹配或文字處理。
from typing import List, Dict, Tuple, Optional, Set  # 提供清晰的型別標註（type hints）。

# 每一行樹狀輸出，對應一個「視覺行內容」與一個「相對路徑 key」：
# - line: 真正印在目錄樹上的那一行文字（例如 '├── src/core/engine.py'）。
# - key : 對應的邏輯路徑（例如 'src/core/engine.py' 或 'src/core/'），
#         用來在結構變動時，穩定地綁定和追蹤註釋。
TreeNode = Tuple[str, Optional[str]]

# 系統級預設忽略名單：
# - 這些目錄／檔案名稱會在生成目錄樹時被自動排除。
# - 即使使用者沒有在前端 UI 裡勾選，它們也不應出現在最終輸出中。
# - 目的是隱藏各種測試快取、虛擬環境與工具產物，讓目錄樹保持乾淨、可閱讀。
SYSTEM_DEFAULT_IGNORE: Set[str] = {
    ".git",
    "__pycache__",
    ".venv",
    ".vscode",
    ".pytest_cache",
    ".mypy_cache",
}

# ==============================================================================
# 【v4.0 核心演算法】 - 註釋解析器 (回歸 v0 智慧)
# ==============================================================================

def _visual_line_to_rel_path(visual_line: str, root_name: str) -> Optional[str]:
    """
    將「樹狀圖中的一行視覺文字」，轉回邏輯上的相對路徑 key。

    例如（假設根目錄名為 'laplace_sentry_control_v2/'）：
        '├── src/'               -> 'src/'
        '│   └── core/'          -> 'src/core/'
        '│   │   └── engine.py'  -> 'src/core/engine.py'

    參數：
        visual_line : 一整行樹狀圖文字，包含前導的 '│   '、'├── ' 等符號。
        root_name   : 根節點在樹狀圖中的顯示名稱，例如 'laplace_sentry_control_v2/'。

    回傳：
        - 對應的相對路徑字串，例如 'src/core/engine.py' 或 'src/core/'。
        - 根節點回傳空字串 ""。
        - 如果該行不是樹狀節點（例如空行、說明行），則回傳 None。
    """

    # 我們先用 rstrip() 去掉右邊多餘的空白，確保後續比對穩定。
    line = visual_line.rstrip()

    # 根節點特判：
    # 如果整行等於根節點名稱（例如 'laplace_sentry_control_v2/'），
    # 我們約定它的相對路徑 key 為空字串 ""。
    if line == root_name:
        return ""

    # 只處理真正的「節點行」：必須包含 '└── ' 或 '├── '
    branch_token = None
    if "└── " in line:
        branch_token = "└── "
    elif "├── " in line:
        branch_token = "├── "
    else:
        # 如果連這兩種符號都沒有，代表這行只是裝飾或空行，直接忽略。
        return None

    # 我們用 branch_token 在這一行中的位置，來反推出「深度」。
    branch_idx = line.index(branch_token)
    # 每一層縮排都由四個字元組成（'│   ' 或 '    '），
    # 所以用「整除 4」就可以得到目前這個節點所在的層級深度。
    depth = branch_idx // 4

    # 取得「節點名稱」本身（可能以 '/' 結尾，代表資料夾）。
    name = line[branch_idx + len(branch_token):]

    # HACK:
    # 我們用一個掛在函式本體上的「層級堆疊（stack）」來記住目前資料夾路徑。
    # 每一個元素都是一層資料夾名稱（以 '/' 結尾），例如 ['src/', 'core/']。
    # 這種設計讓我們可以在「單次逐行掃描」時，逐步重建整個路徑。
    if not hasattr(_visual_line_to_rel_path, "_dir_stack"):
        _visual_line_to_rel_path._dir_stack = []  # type: ignore[attr-defined]
    dir_stack = _visual_line_to_rel_path._dir_stack  # type: ignore[attr-defined]

    # 如果當前節點的「深度」比 stack 短，代表我們往上爬了：
    #   例如從 'src/core/' 跳回 'src/' 同層的其他節點。
    # 這時就把多出來的層級截斷掉。
    if depth <= len(dir_stack):
        dir_stack[:] = dir_stack[:depth]

    # 接下來判斷這個節點是「資料夾」還是「檔案」：
    if name.endswith("/"):
        # 資料夾節點：直接加入層級堆疊，
        # 並把所有層級串起來，形成對應的相對路徑 key。
        dir_stack.append(name)
        rel_path = "".join(dir_stack)
    else:
        # 檔案節點：掛在目前的資料夾堆疊之下。
        rel_path = "".join(dir_stack) + name

    return rel_path


from collections import defaultdict

def _parse_comments_by_path(content_string: str, root_name: str) -> Tuple[Dict[str, str], Dict[str, str]]:
    """
    從舊內容中解析出：
        - path_comments:    { 相對路徑 -> 註解 }
        - basename_comments:{ 檔名(唯一時) -> 註解 }

    路徑優先，檔名只在「唯一」且路徑對不上時當作 fallback。
    """
    if not content_string:
        return {}, {}

    path_comments: Dict[str, str] = {}
    basename_bucket: Dict[str, list[str]] = defaultdict(list)

    tree_block_match = re.search(
        r"<!-- AUTO_TREE_START -->(.*?)<!-- AUTO_TREE_END -->",
        content_string,
        re.DOTALL,
    )
    if not tree_block_match:
        return {}, {}

    tree_block_raw = tree_block_match.group(1).strip()
    if tree_block_raw.startswith("```") and tree_block_raw.endswith("```"):
        content_to_parse = tree_block_raw[3:-3].strip()
    else:
        content_to_parse = tree_block_raw

    # 解析過程需要自己的「目錄 stack」，確保每次呼叫時是乾淨的
    if hasattr(_visual_line_to_rel_path, "_dir_stack"):
        delattr(_visual_line_to_rel_path, "_dir_stack")  # type: ignore[attr-defined]

    for line in content_to_parse.split("\n"):
        if "#" not in line:
            continue

        parts = line.rsplit("#", 1)
        if len(parts) != 2:
            continue

        visual_part = parts[0].rstrip()
        comment_part = parts[1].strip()

        if not visual_part or not comment_part:
            continue

        # 略過自動產生的 TODO，不視為正式註解
        if comment_part.startswith("TODO:"):
            continue

        rel_path = _visual_line_to_rel_path(visual_part, root_name)
        if rel_path is None:
            continue

        path_comments[rel_path] = comment_part

        # 收集 basename，之後只保留「唯一」者做 fallback
        base = os.path.basename(rel_path.rstrip("/"))
        if base:  # 根 ('') 沒有 basename
            basename_bucket[base].append(rel_path)

    # 建立「唯一檔名 -> 註解」對照表
    basename_comments: Dict[str, str] = {}
    for base, paths in basename_bucket.items():
        if len(paths) == 1:
            only_path = paths[0]
            basename_comments[base] = path_comments[only_path]

    return path_comments, basename_comments



# ==============================================================================
#  【v4.0 核心演算法】 - 結構生成器 (視覺穩定性優先)
# ==============================================================================

# 這裡，我們用「def」來 定義（define）一個函式，名稱是「_generate_tree」。
# 它的任務是：根據你電腦裡的真實檔案結構，生成一個視覺上穩定、準確的樹狀圖。
# 我們為函式簽名增加一個新的、可選的參數 ignore_patterns
def _generate_tree(
    root_path: str,
    folder_spacing: int = 0,
    max_depth: Optional[int] = None,
    ignore_patterns: Optional[Set[str]] = None,
) -> Tuple[List[str], List[TreeNode]]:
    """
    產生目錄樹的純文字行列表，並同步產生每一行對應的相對路徑 key。

    - tree_lines: 舊版使用的純文字樹狀行（保持相容）
    - tree_nodes: 每一行搭配一個相對路徑 key（根或非節點則為 None）
    """
    lines: List[str] = []
    nodes: List[TreeNode] = []

    # 根節點顯示名稱，例如 "laplace_sentry_control_v2/"
    root_name = os.path.basename(os.path.normpath(root_path)) + "/"

    # 根節點：對外仍然保留原本的顯示形式
    root_line = root_name
    lines.append(root_line)
    # 根的相對路徑 key 我們定義為空字串 ""
    nodes.append((root_line, ""))

    # 準備忽略名單：系統預設 + 使用者設定（聯集）
    if ignore_patterns:
        ignore_set: Set[str] = SYSTEM_DEFAULT_IGNORE | set(ignore_patterns)
    else:
        ignore_set = set(SYSTEM_DEFAULT_IGNORE)

    def recursive_helper(
        directory: str,
        prefix: str,
        depth: int,
        rel_path: str,
    ):
        """
        directory : 真實檔案系統路徑
        prefix    : 樹狀圖的視覺前綴（由 '│   ' / '    ' 組成）
        depth     : 當前深度（根為 0）
        rel_path  : 目前相對於 root 的路徑字串（例如 'src/core/'）
        """
        # 深度限制檢查
        if max_depth is not None and depth > max_depth:
            return

        try:
            all_entries = os.listdir(directory)
        except FileNotFoundError:
            return

        # 先套用忽略規則
        visible_entries = [
            name for name in all_entries
            if name not in ignore_set
        ]

        # VSCode 風格排序：
        # 1. 資料夾永遠在前
        # 2. 資料夾按字母排序
        # 3. 檔案永遠在後
        # 4. 檔案按字母排序
        dirs: List[str] = []
        files: List[str] = []

        for name in visible_entries:
            full = os.path.join(directory, name)
            if os.path.isdir(full):
                dirs.append(name)
            else:
                files.append(name)

        dirs.sort()
        files.sort()

        # 最終順序：先資料夾，再檔案
        entries = dirs + files

        total = len(entries)
        for idx, entry_name in enumerate(entries):
            is_last = (idx == total - 1)
            full_path = os.path.join(directory, entry_name)
            is_dir = os.path.isdir(full_path)
            display_name = entry_name + "/" if is_dir else entry_name

            # 視覺樹狀行
            branch = "└── " if is_last else "├── "
            line = f"{prefix}{branch}{display_name}"
            lines.append(line)

            # 計算這一行對應的「相對路徑 key」
            # rel_path 代表目前所在的資料夾路徑，例如 "src/core/"
            if rel_path:
                new_rel_path = rel_path + display_name
            else:
                new_rel_path = display_name

            # 統一用 "/" 作為分隔符，資料夾保留結尾 "/"
            if is_dir:
                key = new_rel_path  # 已經有 "/"
            else:
                key = new_rel_path.rstrip("/")

            # 樹狀圖裡這一行是一個節點，有對應的 path key
            nodes.append((line, key))

            # 如果是資料夾，遞迴進去
            if is_dir:
                child_prefix = prefix + ("    " if is_last else "│   ")
                child_rel_path = key  # 對資料夾而言，key 已經是 "xxx/" 型式
                recursive_helper(full_path, child_prefix, depth + 1, child_rel_path)

        # 根層之間的空行（如果有設定）
        if folder_spacing > 0 and depth == 1:
            for _ in range(folder_spacing):
                spacer = ""
                lines.append(spacer)
                nodes.append((spacer, None))

    # 從 root 下層開始遞迴，根本身已經手動加入
    recursive_helper(root_path, prefix="", depth=1, rel_path="")

    return lines, nodes


# ==============================================================================
# 【v4.0 核心演算法】 - 註解合併器 (回歸 v0 智慧)
# ==============================================================================

# 這裡，我們用「def」來 定義（define）一個函式，名稱是「_merge_and_align_comments」。
# 它的任務是：把新生成的樹狀圖和從舊內容中解析出的註解，合併在一起並對齊。

def _merge_and_align_comments_by_path(
    tree_nodes: List[TreeNode],
    path_comments: Dict[str, str],
    basename_comments: Dict[str, str],
) -> List[str]:
    """
    使用「路徑為 key」合併註釋，
    若路徑對不上，且檔名在整棵樹中是唯一的，則回退使用「檔名為 key」。
    """
    final_lines: List[str] = []

    # 1. 計算內容行最長長度（只看有 '──' 的行）
    max_len = 0
    for line, _ in tree_nodes:
        if "──" in line:
            max_len = max(max_len, len(line.rstrip()))

    used_paths: Set[str] = set()
    used_basenames: Set[str] = set()

    # 2. 逐行合併
    for line, path_key in tree_nodes:
        stripped_line = line.rstrip()

        # 空白行或非節點行：原樣輸出
        if path_key is None:
            final_lines.append(line)
            continue

        is_root = (path_key == "")
        comment: Optional[str] = None

        # 優先：用完整路徑配對
        if path_key in path_comments:
            comment = path_comments[path_key]
            used_paths.add(path_key)
        else:
            # 路徑配不到 → 嘗試用「唯一檔名」作為後備
            base = os.path.basename(path_key.rstrip("/"))
            if base and base in basename_comments and base not in used_basenames:
                comment = basename_comments[base]
                used_basenames.add(base)

        if comment:
            padding = " " * (max_len - len(stripped_line) + 2)
            final_lines.append(f"{stripped_line}{padding}# {comment}")
        else:
            # 沒註解的節點：依舊給 TODO（與舊版行為一致）
            if "──" in line or is_root:
                padding = " " * (max_len - len(stripped_line) + 2)
                final_lines.append(f"{stripped_line}{padding}# TODO: Add comment here")
            else:
                final_lines.append(line)

    return final_lines



# ==============================================================================
# 【v4.0 核心演算法】 - 總裝配線 (Public API)
# ==============================================================================

# 這裡，我們用「def」來 定義（define）一個公開的、可以從外部調用的主函式。
# 它的任務是：按順序調用所有內部函式，完成一次完整的生成流程。
# 我們同樣為這個公開的函式，增加一個可選的 ignore_patterns 參數
def generate_annotated_tree(
    root_path,
    old_content_string: str | None = "None",
    folder_spacing=0,
    max_depth=None,
    ignore_patterns=None,
):
    root_name = os.path.basename(os.path.normpath(root_path)) + "/"

    # 1. 解析舊內容中的註釋：路徑 + 檔名 fallback
    path_comments, basename_comments = _parse_comments_by_path(
        old_content_string or "",
        root_name,
    )

    # 2. 產生最新的樹狀結構
    tree_lines, tree_nodes = _generate_tree(
        root_path,
        folder_spacing=folder_spacing,
        max_depth=max_depth,
        ignore_patterns=ignore_patterns,
    )

    # 3. 基於 path + basename 合併註釋
    final_tree_lines = _merge_and_align_comments_by_path(
        tree_nodes,
        path_comments,
        basename_comments,
    )

    return "\n".join(final_tree_lines)



# ==============================================================================
#  主執行區 (Command-Line Interface)
# ==============================================================================
def main():
    """定義並執行程式的命令列介面。"""
    # DEFENSE: 檢查傳入的參數數量是否足夠。
    if len(sys.argv) < 2:
        print("【引擎專家錯誤】：至少需要提供一個『專案路徑』參數！", file=sys.stderr)
        sys.exit(1)

    project_path = sys.argv[1]
    # 我們用一個三元表達式來安全地獲取第二個參數。
    old_content_source = sys.argv[2] if len(sys.argv) > 2 else None
    folder_spacing = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    max_depth = int(sys.argv[4]) if len(sys.argv) > 4 else None

    old_content = None

    # HACK: 這裡的邏輯是為了讓引擎能同時處理兩種輸入源：
    # 1. 從管道傳來的標準輸入 (`-`)
    # 2. 一個檔案路徑
    if old_content_source == "-":
        old_content = sys.stdin.read()
    elif old_content_source and os.path.isfile(old_content_source):
        try:
            with open(old_content_source, 'r', encoding='utf-8') as f:
                old_content = f.read()
        except Exception as e:
            print(f"【引擎專家錯誤】：讀取舊內容檔案 '{old_content_source}' 時出錯！\n  -> {e}", file=sys.stderr)
            sys.exit(3)
    else:
        # 如果既不是 `-` 也不是有效檔案，就直接把參數本身當作內容。
        old_content = old_content_source

    # 調用我們的「總裝配線」函式來生成最終的目錄樹。
    final_tree = generate_annotated_tree(
        project_path,
        old_content,
        folder_spacing=folder_spacing,
        max_depth=max_depth
    )

    # 將結果打印到標準輸出。
    print(final_tree)

# 這是一個 Python 的標準寫法。
# 它確保只有當這個文件被直接執行時，main() 函式才會被調用。
if __name__ == "__main__":
    main()
