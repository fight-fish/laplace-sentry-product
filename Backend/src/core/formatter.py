# ==============================================================================
# 模組職責：formatter.py
# - 負責根據指令選擇適用的格式化策略
# - 提供 obsidian/raw 等輸出風格的包裝能力
# - 作為 CLI 工具，與外部管道串接以完成最終輸出格式統一
#
# 設計理念：
# - 單一職責：只處理格式化，不涉入引擎邏輯
# - 可擴展：FUTURE 可新增更多策略（typora / notion / html 等）
# ==============================================================================

import sys       # 用於讀取從標準輸入傳來的資料。
import argparse  # 專業的「指令翻譯官」，負責解析命令列參數。

# 這裡，我們用「def」來 定義（define）一個我們這個腳本最主要的函式，名叫「main」。
def main():
    
    # 我們讓「指令翻譯官（argparse）」準備好開始工作。
    parser = argparse.ArgumentParser(description="為輸入的文本應用特定的格式化策略。")
    
    # 我們告訴翻譯官，我們需要一個名叫「--strategy」的參數。
    # DEFENSE:
    # 「default='raw'」是一個防禦性設計。它確保了即使外部調用者忘記提供策略，
    # 我們的程式也不會崩潰，而是會執行一個安全的、預設的行為。
    parser.add_argument(
        '--strategy', 
        default='raw', 
        help="要應用的格式化策略 (例如: 'obsidian', 'raw')"
    )
    
    # 翻譯官開始正式解析傳入的指令，並把結果存放在「args」這個盒子裡。
    args = parser.parse_args()

    # 我們用「sys」工具，從「標準輸入（stdin）」中，讀取（read）所有傳來的「原材料」內容。
    raw_content = sys.stdin.read()

    # FUTURE:
    # 這裡的「if...else...」結構是一個可擴展的設計。未來如果我們想支持
    # 新的筆記軟體（如 Typora 或 Notion），只需要在這裡增加新的「elif」判斷分支即可。
    # 我們用「if」來判斷，如果（if）指令中指定的策略（args.strategy）是「obsidian」...
    if args.strategy == 'obsidian':
        # ...我們就在「原材料」的頭尾，分別加上三個反引號，把它包裹成一個 Markdown 代碼塊。
        formatted_content = f"```\n{raw_content.strip()}\n```"
    # 否則（else），如果不是「obsidian」策略...
    else:
        # ...我們就什麼都不做，直接把「原材料」當作「成品」。
        formatted_content = raw_content
    
    # 最後，我們把「包裝」好的成品，打印（print）到標準輸出，讓下一個流程可以使用。
    print(formatted_content)

# 這是一個 Python 的標準寫法。
# 我們用「if __name__ == "__main__"」來判斷，如果（if）這個腳本是直接被執行的...
if __name__ == "__main__":
    # ...我們就去執行上面定義好的「main」函式。
    main()
