# ==========================================
#   Sentry v2.0 Sandbox - Import Section
# ==========================================

# --- 1. 系統與基礎工具 ---
import sys
import json
from typing import List, Dict, Any
import math
from pathlib import Path

# --- 2. PySide6 核心與介面元件 ---
from PySide6.QtCore import (
    Qt, 
    QPoint, 
    QSize, 
    QTimer,            # (心跳計時器)
    QPropertyAnimation,# (動畫工具，預留給之後用)
    QEasingCurve,
    Signal,
    QSettings,
)

from PySide6.QtGui import (
    QIcon, 
    QAction, 
    QPainter,          # (畫筆)
    QPen, 
    QColor, 
    QBrush, 
    QRadialGradient,   # (漸層)
    QCursor,
    QPalette,
    QPainterPath        # (貝茲曲線工具
)

from PySide6.QtWidgets import (
    QApplication,
    QWidget,
    QVBoxLayout,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QSystemTrayIcon,
    QMenu,
    QStyle,
    QStackedWidget,
    QMessageBox,
    QInputDialog,
    QSpacerItem,
    QSizePolicy,
    QTableWidget,
    QTableWidgetItem,
    QSplitter,
    QFrame,
    QAbstractItemView,
    QLineEdit,
    QFileDialog,
    QListWidgetItem,
    QListWidget,
    QDialogButtonBox,
    QDialog,
    QCheckBox,
    QTreeWidget,
    QTreeWidgetItem,
    QHeaderView,
)

# --- 3. 專案內部模組 ---
from src.backend import adapter

# ==========================================
#   [New] 直覺引導氣泡 (Status Bubble)
# ==========================================
class StatusBubble(QWidget):
    """
    懸浮在眼睛下方的對話氣泡。
    - 支援淡入淡出
    - 支援自動消失
    - 視覺風格：半透明黑底 + 白字
    """
    def __init__(self, parent=None):
        super().__init__(parent)
        # 設定為子視窗，但無邊框
        self.setWindowFlags(Qt.WindowType.SubWindow | Qt.WindowType.FramelessWindowHint)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        
        # 預設隱藏
        self.hide()
        
        # --- 介面佈局 ---
        layout = QVBoxLayout(self)
        layout.setContentsMargins(10, 8, 10, 8)
        
        self.label = QLabel("提示訊息")
        self.label.setStyleSheet("""
            color: #FFFFFF;
            font-weight: bold;
            font-size: 11px;
        """)
        self.label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(self.label)
        
        # --- 自動消失計時器 ---
        self.fade_timer = QTimer(self)
        self.fade_timer.setSingleShot(True)
        self.fade_timer.timeout.connect(self.hide_bubble)

    def show_message(self, text: str, duration: int = 3000):
        """顯示訊息，並在 duration (毫秒) 後自動消失"""
        self.label.setText(text)
        self.adjustSize() # 自動調整大小以適應文字
        self.show()
        
        # 如果有設定時間，就啟動倒數
        if duration > 0:
            self.fade_timer.start(duration)

    def hide_bubble(self):
        self.hide()

    def paintEvent(self, event):
        """繪製圓角半透明背景"""
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        
        rect = self.rect()
        
        # 半透明黑底
        brush_color = QColor(0, 0, 0, 180)
        painter.setBrush(QBrush(brush_color))
        painter.setPen(Qt.PenStyle.NoPen)
        
        # 畫圓角矩形
        painter.drawRoundedRect(rect, 10, 10)
        
        # (選配) 畫一個小三角形指向上面 (對話框的尾巴)
        # 這裡先保持簡單圓角，以免計算太複雜

# ==========================================
#   View A: 哨兵之眼 (Sentry Eye) - 正式實作
# ==========================================
class SentryEyeWidget(QWidget):
    
    # 這是我們的靜態常數
    DEFAULT_OUTPUT_FILENAMES = ["README.md", "README.MD", "readme.md", "INDEX.md", "index.md"]

    # 這是我們的靜態方法 (可以直接呼叫 SentryEyeWidget._find_default_output_file)
    @staticmethod
    def _find_default_output_file(folder_path: Path) -> str | None:
        """[核心] 檢查資料夾內是否存在預設寫入檔，並返回第一個存在的路徑。"""
        # 我們用「for...in...」這個結構，來一個一個地處理「預設寫入檔名稱（filename）」。
        for filename in SentryEyeWidget.DEFAULT_OUTPUT_FILENAMES:
            target_path = folder_path / filename
            # 我們用「if」來判斷，如果（if）這個路徑是一個檔案（is_file）...
            if target_path.is_file():
                # 就回傳（return）這個路徑的字串。
                return str(target_path)
        # 如果迴圈結束都沒找到，就回傳（return）空值（None）。
        return None

    def __init__(self, switch_callback, shutdown_callback=None, eye_size: int = 480, eye_size_callback=None):
        # 我們 呼叫（call）父類別的初始化。
        super().__init__()
        
        # [關鍵修正] 我們 開啟（enable）滑鼠追蹤，這樣沒按按鍵時也能偵測懸停！
        self.setMouseTracking(True) 
        # 告訴視窗：我願意 接收（accept）拖曳進來的東西
        self.setAcceptDrops(True)
        # 設定背景透明
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        
        self.old_pos = None
        self.switch_callback = switch_callback
        self.shutdown_callback = shutdown_callback
        self.eye_size = int(eye_size)
        self.eye_size_callback = eye_size_callback
        
        # [新增] 瞳孔懸停狀態 (用於變色)
        # 我們預設它為 False (沒有懸停)。
        self.is_pupil_hovered = False

        self.pending_folder = None

        # --- 動畫與計時器 (維持原樣) ---
        self.timer = QTimer(self)
        self.timer.timeout.connect(self.update)
        self.timer.start(50)
        self.phase = 0
        self.eating_frame = 0

        # 初始化氣泡
        self.bubble = StatusBubble(self)
        self.bubble.move(10, 140)

        # 瞳孔運動與眨眼 (維持原樣)
        self.pupil_offset = QPoint(0, 0)
        self.target_offset = QPoint(0, 0)
        
        self.saccade_timer = QTimer(self)
        self.saccade_timer.timeout.connect(self._trigger_saccade)
        self.saccade_timer.start(3000)

        self.blink_timer = QTimer(self)
        self.blink_timer.timeout.connect(self._trigger_blink)
        self.blink_timer.start(4000)
        self.is_blinking = False
        self.blink_progress = 0.0
        self.blink_repeats = 0

        self.enable_guidance = True
        self.enable_smart_match = True
        self.setToolTip("👁️ 哨兵之眼：請將「專案資料夾」拖曳至此以開始監控")

    def sizeHint(self) -> QSize:
        return QSize(self.eye_size, self.eye_size)

    def minimumSizeHint(self) -> QSize:
        return QSize(self.eye_size, self.eye_size)

    def set_eye_size(self, size: int) -> None:
        self.eye_size = int(size)
        self.updateGeometry()
        self.resize(self.eye_size, self.eye_size)
        self.update()

    def _trigger_saccade(self): 
        """隨機產生眼球移動目標""" 
        import random 
        # 隨機決定下一次動的時間 (2~5秒) 
        self.saccade_timer.setInterval(random.randint(2000, 5000))
        # 隨機決定看的方向 (範圍限制在 +/- 15px 以內，避免脫窗)
        # 這裡使用整數簡化計算
        rx = random.randint(-15, 15)
        ry = random.randint(-10, 10) # 上下移動範圍小一點，比較自然
        self.target_offset = QPoint(rx, ry)

    def _trigger_blink(self):
        """觸發眨眼動畫 (設定雙連眨)"""
        import random
        if self.eating_frame > 0:
            return

        # --- [教學] 修改這裡的數字來控制頻率 ---
        # 4000 = 4秒, 8000 = 8秒
        # 這表示：每隔 4~8 秒之間，會觸發一次眨眼
        next_interval = random.randint(4000, 8000) 
        self.blink_timer.setInterval(next_interval)
        
        # 開始眨眼
        self.is_blinking = True
        self.blink_progress = 0.0
        
        # [設定] 設定為 1，表示這次眨完後，還要「再眨 1 次」(共 2 次)
        # 如果您想要單次眨眼，改成 0 即可
        self.blink_repeats = 1

    def set_preferences(self, guidance: bool, smart_match: bool):
        """[Task 9.4] 這是接收外部設定的「接口」，用來更新開關狀態。"""
        self.enable_guidance = guidance
        self.enable_smart_match = smart_match

        # [UX 優化] 根據引導開關，決定是否顯示滑鼠懸停提示 (Tooltip)
        if guidance:
            self.setToolTip("👁️ 哨兵之眼：請將「專案資料夾」拖曳至此以開始監控")
        else:
            self.setToolTip("") # 清空就不會顯示，達成「勾掉後永不出現」的需求

        # 如果（if）關閉了引導，且氣泡還在顯示，就把它藏起來（hide）。
        if not guidance and hasattr(self, 'bubble'):
            self.bubble.hide()

    def resizeEvent(self, event):
        """當視窗大小改變時，調整氣泡位置"""
        super().resizeEvent(event)
        # 讓氣泡水平置中
        if hasattr(self, 'bubble'):
            bx = (self.width() - self.bubble.width()) // 2
            # 放在高度的 85% 處 (眼睛下方)
            by = int(self.height() * 0.85) 
            self.bubble.move(bx, by)
        
    def paintEvent(self, event):
        """繪製精細版哨兵之眼 (v2.1: 中空機械眼 + 雷射邊框)"""
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        
        # --- 0. 動畫核心計算 ---
        self.phase += 0.1
        breath_factor = 0.85 + 0.15 * abs(math.sin(self.phase))
        # --- [新增] 瞳孔物理運動 (Ease-out 插值) ---
        # 讓目前位置追趕目標位置，係數 0.1 代表速度
        dx = self.target_offset.x() - self.pupil_offset.x()
        dy = self.target_offset.y() - self.pupil_offset.y()

        # 更新目前位置 (轉成整數以利繪圖)
        new_x = self.pupil_offset.x() + int(dx * 0.1)
        new_y = self.pupil_offset.y() + int(dy * 0.1)
        self.pupil_offset = QPoint(new_x, new_y)
        # 狀態判斷
        is_eating = self.eating_frame > 0
        if is_eating:
            self.eating_frame -= 1
            breath_factor = 1.2 
            
        # 判斷是否處於「飢渴狀態 (Hunting Mode)」
        is_hungry = self.pending_folder is not None

        rect = self.rect()
        center = rect.center()
        w = rect.width()
        h = rect.height()
        
        # [動態適配] 使用相對比例，而非固定數值
        eye_width = w * 0.8
        eye_height = h * 0.5

        # --- 定義色票 (Color Palette) ---
        if is_eating:
            # 吞噬中：綠色
            main_color = QColor(50, 255, 50)
            glow_color = QColor(0, 200, 0)
        # [關鍵修正] 新增這段：如果（elif）懸停在瞳孔上，就變紅色警戒
        elif self.is_pupil_hovered: 
            main_color = QColor(255, 60, 60) # 亮紅
            glow_color = QColor(255, 0, 0)   # 純紅
        elif is_hungry:
            # 飢渴中：橘紅色
            main_color = QColor(255, 140, 0) 
            glow_color = QColor(255, 69, 0)  
        else:
            # 正常：青色
            main_color = QColor(0, 255, 255)
            glow_color = QColor(0, 150, 255)

        # --- [NEW] 0.5 底層陰影 (Shadow Layer) ---
        # 這是一層墊在下面的黑色光暈，確保在淺色桌面上也能看見眼睛
        shadow_radius = (eye_width / 2) * breath_factor * 1.3 # 比光暈大一點點
        shadow = QRadialGradient(center, shadow_radius)
        
        # 設定黑色漸層 (中心半透明黑 -> 邊緣全透明)
        shadow.setColorAt(0.0, QColor(0, 0, 0, 180)) # 中心較黑
        shadow.setColorAt(0.7, QColor(0, 0, 0, 50))  # 邊緣淡黑
        shadow.setColorAt(1.0, QColor(0, 0, 0, 0))   # 全透明
        
        painter.setBrush(QBrush(shadow))
        painter.setPen(Qt.PenStyle.NoPen)
        painter.drawEllipse(center, shadow_radius, shadow_radius)

        # --- 1. 背景光暈 ---
        halo_radius = (eye_width / 2) * breath_factor * 1.2
        halo = QRadialGradient(center, halo_radius)
        
        # 設定透明度
        c1 = QColor(main_color)
        c1.setAlpha(100 if not is_eating else 180)
        c2 = QColor(glow_color)
        c2.setAlpha(40 if not is_eating else 50)
        
        halo.setColorAt(0.0, c1)
        halo.setColorAt(0.5, c2)
        halo.setColorAt(1.0, QColor(0, 0, 0, 0))
        
        painter.setBrush(QBrush(halo))
        painter.setPen(Qt.PenStyle.NoPen)
        painter.drawEllipse(center, halo_radius, halo_radius)
        
        # --- 2. 眼眶 (上下眼瞼) ---
        path = QPainterPath()
        left_pt = QPoint(int(center.x() - eye_width/2), int(center.y()))
        right_pt = QPoint(int(center.x() + eye_width/2), int(center.y()))
        top_ctrl = QPoint(int(center.x()), int(center.y() - eye_height))
        bottom_ctrl = QPoint(int(center.x()), int(center.y() + eye_height))
        
        path.moveTo(left_pt)
        path.quadTo(top_ctrl, right_pt)
        path.quadTo(bottom_ctrl, left_pt)
        
        # 外框顏色
        pen_color = QColor(main_color)
        pen_color.setAlpha(255)
        pen_glow = QPen(pen_color)
        # [視覺微調] 使用浮點數寬度，讓線條更細緻 (1.5px / 2.5px)
        pen_glow.setWidthF(2.5 if is_eating else 1.5)
        painter.setPen(pen_glow)
        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.drawPath(path)

# --- 3. 瞳孔 (v2.1: 中空雷射環 + 物理運動) ---
        # [關鍵 1] 計算瞳孔的新中心點 (原本的中心 + 偏移量)
        pupil_center = center + self.pupil_offset

        # [關鍵 2] 根據狀態決定瞳孔大小 (維持 Task 9.2.1 的邏輯)
        if is_eating:
            pupil_scale = 0.2
        elif is_hungry:
            pupil_scale = 0.55 
        else:
            pupil_scale = 0.45 

        pupil_r = eye_height * pupil_scale
        
        # [關鍵 3] 繪製 (注意：這裡全部改成用 pupil_center！)
        
        # A. 虹膜 (透明 + 邊框)
        painter.setBrush(Qt.BrushStyle.NoBrush)
        ring_pen = QPen(main_color)
        ring_pen.setWidthF(1.5) 
        painter.setPen(ring_pen)
        # 使用新的中心點繪製
        painter.drawEllipse(pupil_center, pupil_r, pupil_r)
        
        # B. 內圈瞳孔 (黑色實心)
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(QBrush(QColor(0, 0, 0, 220)))
        # 使用新的中心點繪製
        painter.drawEllipse(pupil_center, pupil_r * 0.6, pupil_r * 0.6)

        # --- 4. 眨眼動畫 (v2.2: 單向 + 雙連眨) ---
        if self.is_blinking:
            # 增加進度 (0.35 = 眨得更快一點，因為要眨兩下)
            self.blink_progress += 0.35

            # 計算閉合程度
            if self.blink_progress <= 1.0:
                lid_factor = self.blink_progress
            else:
                lid_factor = 2.0 - self.blink_progress

            # 動畫結束檢查
            if self.blink_progress >= 2.0:
                # [關鍵] 檢查是否需要連眨
                if self.blink_repeats > 0:
                    self.blink_repeats -= 1
                    self.blink_progress = 0.0 # 重置進度，馬上再眨一次
                    lid_factor = 0.0
                else:
                    # 真的結束了
                    self.is_blinking = False
                    self.blink_progress = 0.0
                    lid_factor = 0.0

            # 設定剪裁
            painter.save()
            painter.setClipPath(path)

            # 計算眼皮高度
            # 因為只從上面蓋下來，高度需要是原本的 2 倍才能蓋滿全眼
            lid_h = int(eye_height * 2 * lid_factor)
            
            lid_color = QColor(main_color)
            lid_color.setAlpha(200) 
            painter.setBrush(QBrush(lid_color))
            painter.setPen(Qt.PenStyle.NoPen)

            # 只畫上眼瞼 (從上往下蓋)
            # 起點 Y 是眼眶最高點 (center.y - eye_height)
            painter.drawRect(
                int(center.x() - eye_width/2), 
                int(center.y() - eye_height), 
                int(eye_width), 
                lid_h
            )
            
            painter.restore()

    def mousePressEvent(self, event):
        """記錄點擊起點 (改用全域座標)"""
        from PySide6.QtCore import QPoint
        if event.button() == Qt.MouseButton.LeftButton:
            self.old_pos = event.globalPosition().toPoint()
            # [核心修正] 改用 globalPosition (螢幕座標) 來記錄起點
            # 這樣就算視窗跟著跑，我們也能算出滑鼠實際在桌面上跑了多遠
            self.global_press_pos = event.globalPosition().toPoint()

    def mouseReleaseEvent(self, event):
        """[核心修正 4.0] 全域防手抖判定"""
        from PySide6.QtCore import QPoint
        self.old_pos = None

        # [核心修正] 計算螢幕上的移動距離
        diff = event.globalPosition().toPoint() - self.global_press_pos
        
        # 如果螢幕上移動超過 10 像素，絕對是拖曳，直接結束，不準觸發點擊！
        if diff.manhattanLength() > 10: 
            return 
            
        if event.button() == Qt.MouseButton.LeftButton:
            center = self.rect().center()
            pupil_center = center + self.pupil_offset
            
            # 瞳孔判定邏輯 (維持上一步的精準版)
            base_radius = (self.height() * 0.5) * 0.45 
            black_pupil_radius = base_radius * 0.6 

            # Hit Test 依然使用局部座標 (因為是判斷點在視窗的哪裡)
            distance = ((event.position().x() - pupil_center.x()) ** 2 + 
                        (event.position().y() - pupil_center.y()) ** 2) ** 0.5

            if distance < black_pupil_radius:
                # 點擊黑色瞳孔 -> 關機
                if self.shutdown_callback:
                    self.bubble.show_message("💤 正在關閉 Sentry...", 1500)
                    QTimer.singleShot(100, self.window().close)
                    QTimer.singleShot(500, self.shutdown_callback)
                else:
                    self.window().close()
            else:
                # 點擊黑色瞳孔以外 -> 切換管理
                self.bubble.hide()
                self.switch_callback()

    def mouseMoveEvent(self, event):
        """[核心修正 3.0] 同步縮小懸停(Hover)的紅色警戒範圍"""
        # 1. 拖曳邏輯
        if self.old_pos:
            delta = event.globalPosition().toPoint() - self.old_pos
            self.window().move(self.window().pos() + delta)
            self.old_pos = event.globalPosition().toPoint()
            
        # 2. 懸停偵測
        center = self.rect().center()
        pupil_center = center + self.pupil_offset
        
        # [關鍵修正] 這裡也要同步改用黑色瞳孔的半徑，讓紅色變色也只在黑色區域觸發
        base_radius = (self.height() * 0.5) * 0.45 
        black_pupil_radius = base_radius * 0.6 
        
        distance = ((event.position().x() - pupil_center.x()) ** 2 + 
                    (event.position().y() - pupil_center.y()) ** 2) ** 0.5

        if distance < black_pupil_radius:
            # --- 進入黑色瞳孔 ---
            if not self.is_pupil_hovered:
                self.is_pupil_hovered = True
                self.update() 
            
            if self.enable_guidance and self.bubble.isHidden():
                self.bubble.show_message("🔴 單擊此處可關閉系統", 0)
        else:
            # --- 離開黑色瞳孔 ---
            if self.is_pupil_hovered:
                self.is_pupil_hovered = False
                self.update()
            
            if not self.bubble.fade_timer.isActive():
                self.bubble.hide_bubble()
                
        super().mouseMoveEvent(event)

        # --- 拖曳事件處理 ---
    def dragEnterEvent(self, event):
        """當拖曳物進入視窗時觸發"""
        # 我們檢查（check）拖曳物是否包含檔案路徑（Urls）。
        if event.mimeData().hasUrls():
            # 如果有，我們就接受（accept）這個動作，游標會變。
            event.accept()
        else:
            # 否則，我們忽略（ignore），游標顯示禁止符號。
            event.ignore()

    def dropEvent(self, event):
        """處理放下事件：氣泡回饋版 (Status Bubble Integration)"""
        urls = event.mimeData().urls()
        if not urls:
            return
            
        path_str = urls[0].toLocalFile()
        path_obj = Path(path_str)
        
        # --- [Priority 0] 解除飢餓狀態 ---
        if self.pending_folder:
            if path_obj.is_file():
                folder = self.pending_folder
                target_file = path_str
                self.pending_folder = None
                self._execute_add_project(folder, target_file)
                event.accept()
            else:
                # [氣泡] 錯誤提示
                self.bubble.show_message("❌ 錯誤：請餵我「檔案」作為寫入目標！", 3000)
                event.ignore()
            return

        # --- [Layer 1] 舊雨判定 ---
        if path_obj.is_dir():
            match_proj = adapter.match_project_by_path(path_str)

            if match_proj:
                if match_proj.status == "monitoring":
                    adapter.trigger_manual_update(match_proj.uuid)
                    # [氣泡] 單次更新回饋
                    self.bubble.show_message(f"✨ 專案「{match_proj.name}」\n已觸發單次更新！", 3000)
                else:
                    adapter.toggle_project_status(match_proj.uuid)
                    # [氣泡] 啟動回饋
                    self.bubble.show_message(f"👁️ 歡迎回來，{match_proj.name}。\n哨兵已啟動！", 4000)
                
                event.accept()
                return

        # --- [Layer 2 & 3] 新專案處理 ---
        if path_obj.is_dir():
            # Layer 2: 智慧預設
            default_file = self._find_default_output_file(path_obj)
            # 我們用「if」同時檢查：是否開啟了智慧配對（enable_smart_match）以及是否找到了預設檔。
            if self.enable_smart_match and default_file:
                # [氣泡] 預設檔命中提示 (在彈出輸入框前先給個提示)
                self.bubble.show_message("✨ 已鎖定預設檔，準備啟動...", 2000)
                # 這裡稍微延遲一下再彈出輸入框，讓氣泡能被看到
                QTimer.singleShot(500, lambda: self._execute_add_project(str(path_obj), default_file))
            else:
                # Layer 3: 飢餓模式
                self.pending_folder = str(path_obj)
                self.update() 
                # 用「if」判斷：只有在開啟引導（enable_guidance）時，才顯示氣泡8秒。
                if self.enable_guidance:
                    self.bubble.show_message("🟠 收到資料夾！\n請再拖入「寫入檔」給我...", 8000)
            event.accept()
            
        elif path_obj.is_file():
            # [UX 修正] View A 不接受單獨的檔案，因為不知道專案根目錄在哪
            # 顯示錯誤氣泡引導使用者
            self.bubble.show_message("❌ 請拖曳「專案資料夾」而非單一檔案！", 3000)
            event.ignore()


    def _execute_add_project(self, folder, output_file):
        """[內部工具] 執行最終的新增動作"""
        path_obj = Path(folder)
        default_name = path_obj.name
        
        # 詢問別名
        name, ok = QInputDialog.getText(self, "新哨兵設定", "請輸入專案別名：", text=default_name)
        if not ok or not name:
            # 如果取消，記得把暫存清空，不然會卡在飢餓狀態
            self.pending_folder = None
            return

        try:
            adapter.add_project(name=name, path=folder, output_file=output_file)
            # [新增] 觸發吞噬動畫 (持續約 20 幀)
            self.eating_frame = 20
            
            # [UX 優化] 改用氣泡通知，不阻斷操作，並顯示正確檔名
            actual_filename = Path(output_file).name
            success_msg = f"✔ 已加入哨兵：{name}\n📄 目標：{actual_filename}"
            
            # 延遲一下讓吞噬動畫跑一會兒，再顯示成功氣泡
            QTimer.singleShot(600, lambda: self.bubble.show_message(success_msg, 4000))
            
        except Exception as e:
            QMessageBox.critical(self, "新增失敗", str(e))
            self.pending_folder = None # 失敗也要重置

    def _real_add_project(self, path_obj):
        """[真實邏輯] 呼叫 Adapter 新增專案 (含智慧引導)"""
        folder_path = str(path_obj)
        default_name = path_obj.name
        
        # 1. 詢問別名
        name, ok = QInputDialog.getText(self, "新哨兵設定", "請輸入專案別名：", text=default_name)
        if not ok or not name:
            return

        # 2. 尋找第一個存在的寫入檔 (大小寫不敏感檢查)
        # HACK: 直接複製靜態常數到區域變數，避免 Pylance 在 f-string 內報錯
        DEFAULT_NAMES = SentryEyeWidget.DEFAULT_OUTPUT_FILENAMES 
        
        # 我們現在直接呼叫 SentryEyeWidget 類別內的靜態方法
        output_file = SentryEyeWidget._find_default_output_file(path_obj)

        # 舊有邏輯：如果一個預設寫入檔都找不到，就報錯。
        if output_file is None:
            # 提示（show warning）：未找到預設寫入檔，無法自動註冊。
            QMessageBox.warning(self, "Sentry 警告",
                                f"此資料夾未找到預設寫入檔：{DEFAULT_NAMES} 中的任何一個。\n" # 使用新的區域變數
                                "請先手動創建一個 Markdown 檔案，或使用控制台手動新增專案。",
                                QMessageBox.StandardButton.Ok)
            # 用「return」結束新增流程。
            return

        # 3. 呼叫後端 (使用找到的 output_file)
        try:
            # 嘗試快速新增
            adapter.add_project(name=name, path=folder_path, output_file=output_file)
            # R2 修正: 確保成功訊息顯示的是實際找到的檔名，而不是硬編碼的 README.md。
            actual_filename = Path(output_file).name 
            QMessageBox.information(self, "新增成功", f"已加入哨兵：{name}\n目標：{actual_filename}")
            
        except Exception as e:
            # --- 失敗後的智慧引導 ---
            error_msg = str(e)
            
            # 【關鍵優化】如果找不到預設檔案（R2 暫時解法）
            # 或者是後端報錯，我們直接引導使用者去控制台。
            if "不存在" in error_msg or "No such file" in error_msg or "已被佔用" in error_msg:
                QMessageBox.warning(
                    self, 
                    "新增失敗 - 需要手動修正", 
                    f"快速新增失敗：找不到預設寫入檔，或專案已被佔用。\n\n已為您切換至【控制台】，請在下方手動輸入路徑。",
                    QMessageBox.StandardButton.Ok
                )
                
                # 執行切換到 View B (控制台) 的動作
                self.switch_callback() # 呼叫 go_to_dashboard
                
                # 這裡未來可以新增邏輯：自動填入 View B 的輸入框
                # 但目前 View B 的輸入框邏輯還沒完全移植，先只做到切換。
                
            else:
                # 其他錯誤（例如後端崩潰、Adapter 通訊失敗）直接報錯
                QMessageBox.critical(self, "新增失敗", error_msg)

    def contextMenuEvent(self, event):
        """右鍵選單：提供 Eye 尺寸切換，並保留飢餓狀態的取消入口"""
        menu = QMenu(self)
        menu.setStyleSheet("""
            QMenu { 
                background-color: rgba(20, 20, 30, 240); 
                color: white; 
                border: 1px solid #00D8FF; 
                border-radius: 5px;
                padding: 5px;
            }
            QMenu::item:selected {
                background-color: #155A6C;
            }
        """)

        # --- 1. Eye 大小子選單 ---
        size_menu = menu.addMenu("👁️ Eye 大小")

        size_options = [
            ("小（320）", 320),
            ("中（480）", 480),
            ("大（560）", 560),
        ]

        for label, size in size_options:
            action = QAction(label, size_menu)
            action.setCheckable(True)
            action.setChecked(self.eye_size == size)

            callback = self.eye_size_callback
            if callback is not None:
                action.triggered.connect(lambda checked=False, s=size, cb=callback: cb(s))

            size_menu.addAction(action)

        # --- 2. 飢餓模式時，保留取消暫存入口 ---
        if self.pending_folder:
            menu.addSeparator()

            folder_name = Path(self.pending_folder).name
            action_cancel = QAction(f"❌ 取消暫存：{folder_name}", menu)

            def do_cancel():
                self.pending_folder = None
                self.eating_frame = 0
                self.update()
                self.bubble.show_message("已取消操作，回到待機狀態。", 2000)

            action_cancel.triggered.connect(do_cancel)
            menu.addAction(action_cancel)

        # 在滑鼠位置彈出
        menu.exec(event.globalPos())

    def mouseDoubleClickEvent(self, event):
        """雙擊隱藏視窗"""
        if event.button() == Qt.MouseButton.LeftButton:
            self.window().hide()

class PreviewDropFrame(QFrame):
    """右下角臨時資料夾拖入區（只接收資料夾）。"""

    def __init__(self, on_folder_dropped, parent=None):
        super().__init__(parent)
        self.on_folder_dropped = on_folder_dropped
        self.setAcceptDrops(True)

        self._normal_style = """
            QFrame#previewDropFrame {
                border: 2px dashed #cc4444;
                border-radius: 8px;
                background-color: #fffdfd;
            }
        """

        self._hover_style = """
            QFrame#previewDropFrame {
                border: 2px dashed #66aaff;
                border-radius: 8px;
                background-color: #f0f7ff;
            }
        """

    def _set_hover_style(self, hover: bool):
        if hover:
            self.setStyleSheet(self._hover_style)
            self.setMinimumHeight(196)
        else:
            self.setStyleSheet(self._normal_style)
            self.setMinimumHeight(180)

    def dragEnterEvent(self, event):
        mime = event.mimeData()
        if mime.hasUrls():
            urls = mime.urls()
            if urls:
                local_path = urls[0].toLocalFile()
                if local_path and Path(local_path).is_dir():
                    self._set_hover_style(True)
                    event.acceptProposedAction()
                    return
        event.ignore()

    def dragLeaveEvent(self, event):
        self._set_hover_style(False)
        super().dragLeaveEvent(event)

    def dropEvent(self, event):
        self._set_hover_style(False)

        urls = event.mimeData().urls()
        if not urls:
            event.ignore()
            return

        local_path = urls[0].toLocalFile()
        if local_path and Path(local_path).is_dir():
            if callable(self.on_folder_dropped):
                self.on_folder_dropped(local_path)
            event.acceptProposedAction()
            return

        event.ignore()
class IgnoreSettingsDialog(QDialog):
    """
    忽略清單設定視窗：
    - 顯示候選名單 (Adapter 提供)
    - 允許勾選/取消
    - 允許手動新增
    """
    def __init__(self, parent=None, project_name=""):
        super().__init__(parent)
        self.setWindowTitle(f"編輯忽略規則 - {project_name}")
        self.resize(500, 600)
        
        layout = QVBoxLayout(self)

        # 1. 說明文字
        layout.addWidget(QLabel("勾選要忽略的檔案或資料夾（變更將觸發哨兵重啟）："))

        # 2. 列表區 (含複選框)
        self.list_widget = QListWidget()
        layout.addWidget(self.list_widget)

        # 3. 手動新增區
        input_layout = QHBoxLayout()
        self.new_pattern_edit = QLineEdit()
        self.new_pattern_edit.setPlaceholderText("手動輸入規則 (例: *.tmp)")
        btn_add = QPushButton("新增")
        btn_add.clicked.connect(self._on_add_pattern)
        
        input_layout.addWidget(self.new_pattern_edit)
        input_layout.addWidget(btn_add)
        layout.addLayout(input_layout)

        # 4. 底部按鈕 (確定/取消)
        self.button_box = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel
        )
        self.button_box.accepted.connect(self.accept)
        self.button_box.rejected.connect(self.reject)
        layout.addWidget(self.button_box)

    def load_patterns(self, candidates: list[str], current: set[str]):
        """載入資料並設定勾選狀態"""
        self.list_widget.clear()
        
        # 先把 current 裡有的，但不在 candidates 裡的 (手動加的) 也補進去顯示
        all_items = sorted(set(candidates) | current)
        
        for name in all_items:
            item = QListWidgetItem(name)
            # 設定為可複選
            item.setFlags(item.flags() | Qt.ItemFlag.ItemIsUserCheckable)
            
            # 設定勾選狀態
            if name in current:
                item.setCheckState(Qt.CheckState.Checked)
            else:
                item.setCheckState(Qt.CheckState.Unchecked)
            
            self.list_widget.addItem(item)

    def get_result(self) -> list[str]:
        """收集所有被勾選的項目"""
        results = []
        for i in range(self.list_widget.count()):
            item = self.list_widget.item(i)
            if item.checkState() == Qt.CheckState.Checked:
                results.append(item.text())
        return results

    def _on_add_pattern(self):
        """手動新增規則"""
        text = self.new_pattern_edit.text().strip()
        if not text:
            return
            
        # 檢查是否重複
        existing = [self.list_widget.item(i).text() for i in range(self.list_widget.count())]
        if text in existing:
            QMessageBox.warning(self, "重複", f"規則 '{text}' 已存在。")
            return

        # 加入列表並預設勾選
        item = QListWidgetItem(text)
        item.setFlags(item.flags() | Qt.ItemFlag.ItemIsUserCheckable)
        item.setCheckState(Qt.CheckState.Checked)
        self.list_widget.addItem(item)
        self.list_widget.scrollToBottom()
        self.new_pattern_edit.clear()

class TargetListWidget(QListWidget):
    """
    專門用於處理寫入檔列表的 QListWidget 子類別。
    它接收專案 UUID 和重載回調函式，直接執行拖曳新增邏輯。
    """
    def __init__(self, uuid, reload_callback, log_callback, parent=None):
        super().__init__(parent)
        # 儲存參數
        self.uuid = uuid 
        self.reload_data = reload_callback 
        self.log_callback = log_callback
        self.VALID_EXTENSIONS = {'.md', '.markdown', '.txt', '.log'}

        # --- 拖曳核心設定 ---
        # 告訴列表：接受拖曳進來的東西
        self.setAcceptDrops(True)
        # 設定模式：只接受「放下 (DropOnly)」，不允許把項目拖出去
        self.setDragDropMode(QAbstractItemView.DragDropMode.DropOnly)
        # 設定選取模式：允許「多選 (ExtendedSelection)」，方便一次刪除多個
        self.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)

        # --- 視覺提示 ---
        # 設定樣式表：給它一個虛線框和提示文字背景，讓它看起來像個「接收區」
        self.setStyleSheet("""
            QListWidget {
                border: 2px dashed #AAAAAA;
                border-radius: 5px;
                background-color: #F9F9F9;
                padding: 5px;
            }
            QListWidget::item {
                background-color: white;
                border-bottom: 1px solid #EEEEEE;
                padding: 4px;
            }
            QListWidget::item:selected {
                background-color: #D2E1F5;
                color: black;
            }
        """)
        # 設定提示文字 (當列表為空時顯示，雖然 QListWidget 預設不支援直接顯示文字，但邊框已經足夠提示)
        self.setToolTip("💡 提示：您可以直接將多個 Markdown 檔案「拖曳」到此列表中加入")

    def dragEnterEvent(self, event):
        """當拖曳物進入列表時觸發"""
        if event.mimeData().hasUrls():
            event.accept()
        else:
            event.ignore()

    # [新增] 處理拖曳移動事件 (這是關鍵！很多時候是這裡拒絕了拖曳)
    def dragMoveEvent(self, event):
        """當拖曳物在列表中移動時觸發"""
        if event.mimeData().hasUrls():
            event.setDropAction(Qt.DropAction.CopyAction)
            event.accept()
        else:
            event.ignore()

    def dropEvent(self, event):
        """處理放下事件：批次呼叫後端追加目標"""
        from pathlib import Path
        from PySide6.QtWidgets import QMessageBox

        urls = event.mimeData().urls()
        if not urls:
            return
            
        added_count = 0
        error_count = 0
        
        for url in urls:
            path_str = url.toLocalFile()
            path_obj = Path(path_str)
            
            # 只處理存在的檔案，且在白名單內
            if path_obj.is_file() and path_obj.suffix.lower() in self.VALID_EXTENSIONS:
                try:
                    # 呼叫後端追加 (複用既有的 adapter 接口)
                    adapter.add_target(self.uuid, path_str)
                    added_count += 1
                    self.log_callback(f"+ 拖曳新增: {Path(path_str).name}")
                except Exception:
                    # 如果後端拒絕 (例如：重複路徑、路徑無效)，我們計數但繼續處理下一個
                    error_count += 1
            
        # 根據結果更新介面與回饋
        if added_count > 0 or error_count > 0:
            self.reload_data() # 刷新列表
            
            # [UX 優化] 不彈窗，改用日誌回報
            if added_count > 0:
                self.log_callback(f"✓ 批次追加完成：{added_count} 個檔案")
            
            if error_count > 0:
                self.log_callback(f"⚠ 略過 {error_count} 個無效/重複檔案")
                
            event.accept()
        else:
            # 失敗也不彈窗，只記錄
            self.log_callback("⚠ 拖曳無效：未發現可用的文字檔案")
            event.ignore()

# 我們用「class」來定義（define）編輯專案設定視窗類別。
class EditProjectDialog(QDialog):
    """
    修改專案設定視窗 (v2.0 - 多目標支援版)：
    - 名稱 (Name) / 路徑 (Path)：【延遲儲存】按下 Save 才寫入。
    - 寫入檔 (Targets)：【即時操作】按下新增/刪除按鈕立即生效。
    """
    def __init__(self, parent=None, project_data: adapter.ProjectInfo | None = None):

        super().__init__(parent)
        self.project_data = project_data # 保留參照以便重新讀取
        self.uuid = project_data.uuid if project_data else ""
        # [新增] 記錄即時操作的次數 (如增刪寫入檔)
        self.change_log = []
        self.setWindowTitle(f"修改專案設定 - {project_data.name if project_data else ''}")
        self.resize(600, 500) # 加高一點以容納列表
        
        self._build_ui(project_data)

    def _build_ui(self, data: adapter.ProjectInfo | None):
        main_layout = QVBoxLayout(self)

        # --- A. 基本資料區 (延遲儲存) ---
        group_basic = QFrame()
        group_basic.setFrameShape(QFrame.Shape.StyledPanel)
        layout_basic = QVBoxLayout(group_basic)
        
        layout_basic.addWidget(QLabel("<b>基本設定 (按下 Save 後生效)</b>"))
        
        # 1. 專案名稱
        self.name_edit = QLineEdit(data.name if data else "")
        layout_basic.addWidget(QLabel("專案名稱 (Alias)："))
        layout_basic.addWidget(self.name_edit)

        # 2. 專案路徑
        self.path_edit = QLineEdit(data.path if data else "")
        layout_basic.addWidget(QLabel("專案資料夾路徑 (Path)："))
        layout_basic.addWidget(self.path_edit)
        layout_basic.addWidget(QLabel("提示：修改路徑可能導致哨兵重啟！"))
        
        main_layout.addWidget(group_basic)
        main_layout.addSpacing(10)

        # --- B. 寫入檔管理區 (即時生效) ---
        group_targets = QFrame()
        group_targets.setFrameShape(QFrame.Shape.StyledPanel)
        layout_targets = QVBoxLayout(group_targets)
        
        layout_targets.addWidget(QLabel("<b>寫入檔管理 (即時生效)</b>"))
        
        # 目標列表
        # 我們替換為專門處理拖曳的 TargetListWidget
        # 傳入 uuid 和 刷新回調函式 (_reload_data)
        # [新增] 傳入 log_callback 以便記錄拖曳新增的日誌
        self.target_list = TargetListWidget(
            uuid=self.uuid, 
            reload_callback=self._reload_data,
            log_callback=self._append_log
        )
        # [新增] 啟用寫入檔列表的拖曳功能
        self.target_list.setAcceptDrops(True)
        self._refresh_target_list(data.output_file if data else [])
        layout_targets.addWidget(self.target_list)
        
        # 按鈕區
        btn_layout = QHBoxLayout()
        btn_add = QPushButton("➕ 追加寫入檔...")
        btn_remove = QPushButton("➖ 移除選中檔")
        
        btn_add.clicked.connect(self._on_add_target)
        btn_remove.clicked.connect(self._on_remove_target)
        
        btn_layout.addWidget(btn_add)
        btn_layout.addWidget(btn_remove)
        layout_targets.addLayout(btn_layout)
        
        main_layout.addWidget(group_targets)

        # --- C. 底部按鈕 ---
        self.button_box = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel
        )
        self.button_box.accepted.connect(self.accept)
        self.button_box.rejected.connect(self.reject)
        main_layout.addWidget(self.button_box)

    def _refresh_target_list(self, targets: List[str]):
        """刷新列表顯示"""
        self.target_list.clear()
        for t in targets:
            self.target_list.addItem(t)

    def _reload_data(self):
        """從後端重新讀取此專案的最新資料 (用於更新列表)"""

        all_projects = adapter.list_projects()
        current = next((p for p in all_projects if p.uuid == self.uuid), None)
        if current:
            self.project_data = current
            self._refresh_target_list(current.output_file)

    def _append_log(self, msg: str):
        self.change_log.append(msg)

    def _on_add_target(self):
        """處理追加寫入檔 (即時)"""
        # HACK: 避免循環引用
        from PySide6.QtWidgets import QFileDialog, QMessageBox
        
        file_path, _ = QFileDialog.getOpenFileName(
            self, "選擇要追加的 Markdown 檔案", "", "Markdown (*.md *.txt);;All Files (*.*)"
        )
        
        if not file_path:
            return

        try:
            # 呼叫後端追加
            adapter.add_target(self.uuid, file_path)
            self._append_log(f"+ 新增: {Path(file_path).name}") 
            # 刷新介面
            self._reload_data()
            QMessageBox.information(self, "成功", "已成功追加寫入目標。")
        except Exception as e:
            QMessageBox.critical(self, "追加失敗", str(e))

    def _on_remove_target(self):
        """處理移除寫入檔 (支援批次移除)"""
        selected_items = self.target_list.selectedItems()
        if not selected_items:
            QMessageBox.warning(self, "提示", "請先選擇要移除的路徑。")
            return
            
        count = len(selected_items)
        
        # 1. 構建確認訊息
        if count == 1:
            target_path = selected_items[0].text()
            msg = f"確定要移除此寫入目標嗎？\n{target_path}"
        else:
            msg = f"確定要移除這 {count} 個寫入目標嗎？"

        # 2. 二次確認
        reply = QMessageBox.question(
            self, "確認移除", msg,
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No
        )
        
        if reply == QMessageBox.StandardButton.Yes:
            # 3. 執行批次移除
            error_count = 0
            last_file_blocked = False # [新增] 標記是否因為「最後一檔」被攔截

            for item in selected_items:
                path_to_remove = item.text()
                try:
                    adapter.remove_target(self.uuid, path_to_remove)
                    self._append_log(f"- 移除: {Path(path_to_remove).name}")
                except Exception as e:
                    # [UX 優化] 檢查錯誤訊息是否為「無法清空」
                    # 這是後端 adapter.remove_target 拋出的 ValueError
                    if "無法清空" in str(e):
                        last_file_blocked = True
                    else:
                        error_count += 1
            
            # 4. 刷新介面
            self._reload_data()
            
            # [UX 優化] 根據不同情況顯示不同訊息
            if last_file_blocked:
                QMessageBox.information(self, "保留項目", "已保留最後一個寫入檔（專案不可清空）。")
            elif error_count > 0:
                QMessageBox.warning(self, "部分失敗", f"有 {error_count} 個檔案移除失敗。")

    def get_changes(self) -> Dict[str, Any]:
        """回傳基本資料的變更 (Name/Path) 以及寫入檔變更"""
        changes = {}
        
        # 1. 檢查名稱變更
        new_name = self.name_edit.text().strip()
        if self.project_data and new_name != self.project_data.name:
            if new_name:
                changes['name'] = new_name

        # 2. 檢查路徑變更
        new_path = self.path_edit.text().strip()
        if self.project_data and new_path != self.project_data.path:
            if new_path:
                changes['path'] = new_path
        
        # 3. [新增] 檢查寫入檔變更
        # 我們收集目前列表中的所有項目
        current_targets = []
        for i in range(self.target_list.count()):
            item = self.target_list.item(i)
            current_targets.append(item.text())
            
        # 與原始資料比對 (轉換成 set 比較內容，忽略順序)
        original_targets = self.project_data.output_file if self.project_data else []
        
        if set(current_targets) != set(original_targets):
            # 如果有變動，將新列表放入 changes
            changes['output_file'] = current_targets
            
        return changes  

# ==========================================
#   [New] 日誌瀏覽器 (Log Viewer) - 翻譯版
# ==========================================
from PySide6.QtWidgets import QTextEdit

# ==========================================
#   [New] 日誌瀏覽器 (Log Viewer) - 時間軸版
# ==========================================
from PySide6.QtWidgets import QTextEdit

class LogViewerWidget(QTextEdit):
    """
    黑底白字的日誌顯示器 (內建翻譯機 + 時間軸)。
    """
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setReadOnly(True)
        # 設定樣式：黑底、灰字、等寬字體
        self.setStyleSheet("""
            QTextEdit {
                background-color: #1e1e1e;
                color: #d4d4d4;
                font-family: 'Microsoft JhengHei', 'Segoe UI Emoji', monospace;
                font-size: 10pt;
                border: 1px solid #333333;
                border-radius: 4px;
                padding: 5px;
            }
        """)
        self.setPlaceholderText("請選擇左側專案以查看日誌...")

    def set_logs(self, logs: list[str]):
        """更新日誌內容 (自動翻譯 + 時間軸分組)"""
        if not logs:
            self.setPlaceholderText("此專案目前沒有日誌紀錄。")
            self.clear()
            return
            
        html_content = ""
        last_date = None
        import re

        for line in logs:
            # 1. 嘗試提取日期 (格式: [YYYY-MM-DD HH:MM:SS])
            match = re.search(r"\[(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})\]", line)
            
            if match:
                date_str = match.group(1) # YYYY-MM-DD
                time_str = match.group(2) # HH:MM:SS
                
                # 如果日期變了，插入一個日期標題
                if date_str != last_date:
                    html_content += f'<br><b><font color="#44AAFF">📅 {date_str}</font></b><br>'
                    last_date = date_str
                
                # 呼叫翻譯機 (傳入 time_str 讓它只顯示時間)
                html_content += self._humanize_log_line(line, time_str) + "<br>"
            else:
                # 沒時間戳記的行 (例如舊日誌或系統訊息)，直接翻譯
                html_content += self._humanize_log_line(line, None) + "<br>"
            
        self.setHtml(html_content)
        
        # 自動捲動到底部
        cursor = self.textCursor()
        cursor.movePosition(cursor.MoveOperation.End)
        self.setTextCursor(cursor)

    def _humanize_log_line(self, raw_line: str, time_str: str | None) -> str:
        """[核心] 將原始日誌翻譯為彩色 HTML"""
        import re
        
        # 定義時間前綴 (如果有傳入 time_str 就用它，否則不顯示)
        t_prefix = f'<font color="#666666">{time_str}</font> ' if time_str else ""

        # 1. 哨兵啟動/停止
        if "哨兵啟動" in raw_line:
            return f'{t_prefix}<font color="#00FFFF">👁️ <b>哨兵已就位，開始監控</b></font>'
        if "Stopping sentry" in raw_line or "已成功發送終止信號" in raw_line:
            return f'{t_prefix}<font color="#888888">💤 哨兵已暫停值勤</font>'

        # 2. 檔案事件 (Created / Modified / Deleted)
        # 注意：這裡的 regex 只需要抓 event 和 filename，時間已經在外面抓過了
        match = re.search(r"\[偵測\] (created|modified|deleted): (.+)", raw_line)
        if match:
            event_type = match.group(1)
            filename = match.group(2)
            
            # 去掉完整路徑，只留檔名
            if "/" in filename or "\\" in filename:
                from pathlib import Path
                filename = Path(filename).name

            if event_type == "created":
                return f'{t_prefix}<font color="#00FF00">✨ 發現新檔案</font> : {filename}'
            if event_type == "modified":
                return f'{t_prefix}<font color="#FFFFFF">📝 偵測到變更</font> : {filename}'
            if event_type == "deleted":
                return f'{t_prefix}<font color="#FF5555">🗑️ 檔案已移除</font> : {filename}'

        # 3. 過熱/靜默 (補回 Muting triggered)
        if "智能靜默" in raw_line or "Muting triggered" in raw_line:
            return f'{t_prefix}<font color="#FFFF00">🛡️ <b>觸發過熱保護 (進入靜默模式)</b></font>'
        
        # 4. 更新指令
        if "成功觸發更新指令" in raw_line:
            return f'{t_prefix}<font color="#44AAFF">✅ 正在執行目錄樹更新...</font>'

        # 5. 黑名單/系統訊息 (淡化處理)
        if "OUTPUT-FILE-BLACKLIST" in raw_line:
            return f'<font color="#555555">🔒 安全機制：已自動排除輸出檔監控</font>'
        if "[Step]" in raw_line:
            return f'<font color="#555555">{raw_line}</font>'

        # 預設：原樣顯示
        return f'<font color="#AAAAAA">{raw_line}</font>'
class DashboardWidget(QWidget):
    """
    Sentry 控制台主視窗
    """
    # [Task 9.4] 定義訊號：(是否啟用引導, 是否啟用智慧配對)
    preferences_changed = Signal(bool, bool)

    # 我們用「def」來 定義（define）初始化方法，並接收統計回調（on_stats_change）。
    def __init__(self, on_stats_change=None, switch_callback=None) -> None:
        # 我們 呼叫（call）父類別的初始化。
        super().__init__()
        # [核心修正] 強制啟用樣式背景繪製 (這行是關鍵！)
        self.setAttribute(Qt.WidgetAttribute.WA_StyledBackground, True)
        # 設定視窗的標題（Window Title）。
        self.setWindowTitle("Sentry 控制台 v1 (UX 測試樣板)")
        # 設定視窗的初始大小（resize），寬 900 像素，高 600 像素。
        self.resize(900, 600)
        # 我們將切換回調函式 儲存（store）起來 
        self.switch_callback = switch_callback
        # [新增] 用於視窗拖曳的變數
        self.old_pos = None
        # 我們將回調函式 儲存（store）起來，供稍後使用。
        self.on_stats_change = on_stats_change

        # [核心修正] 強制設定背景為不透明白色，並加上邊框陰影效果
        # border-radius: 10px 讓四個角稍微圓潤一點，比較現代
        self.setStyleSheet("""
            DashboardWidget {
                background-color: #FFFFFF; 
                border: 1px solid #CCCCCC;
                border-radius: 10px;
            }
        """)

        # # TODO: 這裡的註解將使用通俗比喻來解釋資料結構。
        # 準備一個叫「current_projects」的空籃子（[]），
        # 專門用來存放從後端讀取的專案資訊（adapter.ProjectInfo）。
        self.current_projects: list[adapter.ProjectInfo] = []
        self.new_input_fields: list[QLineEdit] = [] 
        self.new_browse_buttons: list[QPushButton] = []

        # [S-02-02b] 目錄樹註解編輯上下文
        self._current_tree_project_uuid: str = ""
        self._current_tree_path_key: str = ""
        self._current_tree_original_comment: str = ""
        self._current_tree_dirty: bool = False
        self._is_loading_tree_comment: bool = False
        self._is_preview_tree_mode: bool = False

        # 呼叫各類函式來 建立介面 和 載入初始資料。        
        self._build_ui()
                
        # 載入資料
        self._load_ignore_settings()

        # [New] 日誌自動刷新計時器
        # 改為每 5 秒刷新一次，減輕 CPU 負擔
        self.log_timer = QTimer(self)
        self.log_timer.timeout.connect(self._refresh_current_log)
        self.log_timer.start(5000)

        # [Task 9.4-Memory] 初始化設定檔 (sentry_config.ini)
        self.settings = QSettings("sentry_config.ini", QSettings.Format.IniFormat)
        
        # 讀取記憶 (預設為 True)
        mem_guidance = self.settings.value("enable_guidance", True, type=bool)
        mem_smart = self.settings.value("enable_smart_match", True, type=bool)
        
        # [Task 9.4-Memory] 初始化設定檔
        self.settings = QSettings("sentry_config.ini", QSettings.Format.IniFormat)
        
        # 讀取記憶 (並強制轉型為 bool 以滿足 Pylance)
        val_g = self.settings.value("enable_guidance", True, type=bool)
        val_s = self.settings.value("enable_smart_match", True, type=bool)
        
        mem_guidance = bool(val_g)
        mem_smart = bool(val_s)
        
        # 套用設定 (使用 blockSignals 暫時靜音，避免初始化時觸發寫入邏輯)
        self.check_guidance.blockSignals(True)
        self.check_smart.blockSignals(True)
        
        self.check_guidance.setChecked(mem_guidance)
        self.check_smart.setChecked(mem_smart)
        
        self.check_guidance.blockSignals(False)
        self.check_smart.blockSignals(False)

    # --- [新增] 獨立的統計通知函式 ---
    # 我們用「def」來 定義（define）重新計算並通知上層的函式。
    def _notify_stats_update(self) -> None:
        """重新計算監控/靜默數量，並通知 Tray 更新 Tooltip"""
        # 如果沒有設定回調，就不做任何事。
        if not self.on_stats_change:
            return

        running_count = 0
        muting_count = 0
        
        # 我們用「for」來 遍歷（iterate）所有專案。
        for p in self.current_projects:
            if p.status == "monitoring":
                if p.mode == "silent":
                    muting_count += 1
                else:
                    running_count += 1
        
        # 我們 呼叫（call）回調函式，把數字傳出去。
        self.on_stats_change(running_count, muting_count)

    # ---------------------------
    # UI 建構
    # ---------------------------

    # 這裡，我們用「def」來定義（define）建立介面（UI）的函式。
    def _build_ui(self) -> None:
        # 建立主佈局（main_layout），採用垂直佈局（QVBoxLayout），東西將從上往下排。
        main_layout = QVBoxLayout(self)

        # --- 頂部導航區 (返回按鈕) ---
        nav_layout = QHBoxLayout()
        # 依照 UI_Strings_Reference_v2.md 定義的返回按鈕
        btn_back = QPushButton("↩ 返回哨兵之眼")
        # 將按鈕連接到我們在 __init__ 中儲存的回調
        btn_back.clicked.connect(self.switch_callback)

        # 標題
        title_label = QLabel("Sentry 控制台")
        title_label.setStyleSheet("font-weight: bold;")

        nav_layout.addWidget(btn_back)
        nav_layout.addWidget(title_label)
        nav_layout.addStretch(1) # 推到底
        main_layout.addLayout(nav_layout)
        # --- 導航區塊結束 ---

        # 建立一個分割器（QSplitter），它可以讓使用者拖拉調整左右兩側的大小。
        # Qt.Orientation.Horizontal 表示它是水平分割的。
        splitter = QSplitter(Qt.Orientation.Horizontal, self)

        # --- 1. 左側：專案列表 ---
        # 呼叫（call）另一個函式來建立專案表格（project_table）。
        self.project_table = self._build_project_table()
        # 把表格元件（project_table）加入（addWidget）到分割器的左邊。
        splitter.addWidget(self.project_table)

        # --- 2. 右側：專案詳情 ---
        # 呼叫（call）另一個函式來建立專案詳情面板（detail_panel）。
        self.detail_panel = self._build_detail_panel()
        # 把詳情面板（detail_panel）加入（addWidget）到分割器的右邊。
        splitter.addWidget(self.detail_panel)

        # 設定分割器的拉伸比例（setStretchFactor）。
        # 0（左側）設定為 3 的比例。
        splitter.setStretchFactor(0, 3)
        # 1（右側）設定為 4 的比例，讓右側大一點。
        splitter.setStretchFactor(1, 4)

        # --- 3. 下方：忽略設定區 ---
        # 呼叫（call）另一個函式來建立底部的忽略設定區（bottom_panel）。
        bottom_panel = self._build_bottom_panel()

        # --- 4. 底部狀態訊息列 ---
        # 建立一個標籤（QLabel），用來顯示狀態訊息（status_label）。
        self.status_label = QLabel("")
        # 設定標籤的文字在超過寬度時可以自動換行（setWordWrap）。
        self.status_label.setWordWrap(True)

        # --- 5. 建立上下可拖曳分隔 ---
        # 這一層只負責讓「上半整塊」與「下半整塊」之間可以拖曳移動，
        # 不改動上下兩塊內部原本的格局。
        main_splitter = QSplitter(Qt.Orientation.Vertical, self)
        main_splitter.addWidget(splitter)
        main_splitter.addWidget(bottom_panel)
        main_splitter.setStretchFactor(0, 3)
        main_splitter.setStretchFactor(1, 2)

        # --- 6. 組合所有佈局 ---
        # 把上下分割器加入到主佈局。
        main_layout.addWidget(main_splitter)
        # 把狀態標籤（status_label）加入到主佈局的最下方。
        main_layout.addWidget(self.status_label)

        # --- 7. 事件連結 (Signal/Slot) ---
        # 當表格的選擇改變時（itemSelectionChanged），連結（connect）到處理函式。
        self.project_table.itemSelectionChanged.connect(
            self._on_project_selection_changed
        )
        self.tree_viewer.currentItemChanged.connect(self._on_tree_item_changed)
        self.tree_comment_editor.textChanged.connect(self._on_tree_comment_text_changed)
        # 當表格的項目被雙擊時（itemDoubleClicked），連結（connect）到處理函式。
        self.project_table.itemDoubleClicked.connect(
            self._on_project_double_clicked
        )
            
# 這裡，我們用「def」來定義（define）建立專案表格的函式。
    def _build_project_table(self) -> QTableWidget:
        # 建立一個表格元件（QTableWidget）。
        table = QTableWidget(self)

        # 設定（set）選單策略為 CustomContextMenu，這樣才能自訂選單。
        table.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        # 綁定（connect）請求選單訊號到我們的處理函式。
        table.customContextMenuRequested.connect(self._on_table_context_menu)
                
        # 設定表格的欄位數量（setColumnCount）為 4 個。
        table.setColumnCount(4)
        # 設定水平表頭的標籤（setHorizontalHeaderLabels），依序是欄位名稱。
        table.setHorizontalHeaderLabels(["UUID","專案名稱", "監控狀態", "模式"])

        # 設定選取行為（setSelectionBehavior）：點擊任何一個格子時，會選取（SelectRows）整行。
        table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        # 設定選取模式（ExtendedSelection）：支援一次可以選取批量檔案。
        table.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)
        # 設定編輯觸發（setEditTriggers）：關閉所有編輯功能（NoEditTriggers），讓表格只顯示資料。
        table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        # 隱藏垂直表頭（verticalHeader），也就是左側的行號。
        table.verticalHeader().setVisible(False)
        # 開啟交替行顏色（setAlternatingRowColors），讓表格更清晰。
        table.setAlternatingRowColors(True)
        # 關閉表格的排序功能（setSortingEnabled）。
        table.setSortingEnabled(False)
        # 隱藏第 0 欄（UUID），它只用於內部資料處理，不用給使用者看。
        table.setColumnHidden(0, True)

        # 獲取（get）表格的水平表頭（horizontalHeader）元件。
        header = table.horizontalHeader()
        # 設定表頭：讓最後一欄自動拉伸（setStretchLastSection）填滿剩餘空間。
        header.setStretchLastSection(True)

        # ---- 顏色調整：降低藍底對比，改成柔和選取色 ----
        # # HACK: 這裡用 HACK 標籤標註，這是為了處理 Qt 預設的藍色選取背景在 Windows 上對比太高問題。
        # 獲取（get）表格目前的調色盤（palette）。
        palette: QPalette = table.palette()

        # 選取底色：很淡的灰藍（你之後可以自己調整）
        # 設定調色盤的顏色（setColor），指定 Highlight（選取底色）為這個淡藍色。
        palette.setColor(QPalette.ColorRole.Highlight, QColor(210, 225, 245))
        # 選取文字顏色：維持黑色，閱讀比較舒服
        # 設定 HighlightedText（選取後的文字顏色）為黑色。
        palette.setColor(QPalette.ColorRole.HighlightedText, QColor(0, 0, 0))

        # 將調整後的調色盤設定（setPalette）回表格。
        table.setPalette(palette)

        # 回傳（return）設定好的表格元件。
        return table


    def _build_detail_panel(self) -> QFrame:
        # 建立一個框架（QFrame），作為右側面板的容器。
        frame = QFrame(self)
        # 設定框架的外觀形狀（setFrameShape）為帶有樣式（StyledPanel）的面板。
        frame.setFrameShape(QFrame.Shape.StyledPanel)

        # 建立一個垂直佈局（QVBoxLayout），把元件從上往下排。
        layout = QVBoxLayout(frame)

        # --- 上半部：專案詳情 ---
        self.detail_label = QTextEdit()
        self.detail_label.setReadOnly(True)
        self.detail_label.setFrameShape(QFrame.Shape.NoFrame)
        self.detail_label.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAsNeeded)
        self.detail_label.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAsNeeded)
        self.detail_label.setMinimumHeight(120)
        self.detail_label.setPlainText(
            "專案詳情區：\n"
            "選取左側某個專案後，會在這裡顯示其狀態與模式。"
        )
        layout.addWidget(self.detail_label)

        # 加入分隔線
        layout.addSpacing(16)

        # --- [New] 下半部：日誌瀏覽器 ---
        # 標題
        log_title = QLabel("<b>哨兵日誌 (Live Logs)</b>")
        layout.addWidget(log_title)

        # 植入我們剛剛寫好的元件
        self.log_viewer = LogViewerWidget()
        layout.addWidget(self.log_viewer)

        # 回傳（return）設定好的框架元件。
        return frame
    

# 這裡，我們用「def」來定義（define）建立底部面板的函式。
    def _build_bottom_panel(self) -> QFrame:
        # 建立一個框架（QFrame），作為底部面板的容器。
        frame = QFrame(self)
        # 設定框架的外觀形狀（setFrameShape）為帶有樣式（StyledPanel）的面板。
        frame.setFrameShape(QFrame.Shape.StyledPanel)

        # 建立主佈局，採用水平佈局（QHBoxLayout），把左側控制區與右側工作區並排。
        layout = QHBoxLayout(frame)

        # 左側：忽略設定 + 狀態訊息 + 偏好設定（採用垂直佈局）
        left_panel = QVBoxLayout()

        # [1] 忽略設定說明
        self.ignore_info_label = QLabel("忽略設定區（暫時版）：尚未載入設定。")
        self.ignore_info_label.setWordWrap(True)
        left_panel.addWidget(self.ignore_info_label)

        # [2] 狀態訊息列
        self.status_message_label = QLabel("狀態訊息：目前沒有任何訊息。")
        self.status_message_label.setWordWrap(True)
        self.status_message_label.setStyleSheet("color: #666666;")
        left_panel.addWidget(self.status_message_label)

        # [Task 9.4] 偏好設定區塊
        pref_layout = QHBoxLayout()
        pref_layout.setContentsMargins(0, 10, 0, 10)

        self.check_guidance = QCheckBox("啟用氣泡引導")
        self.check_guidance.setChecked(True)
        self.check_guidance.setToolTip("開啟後，哨兵會在桌面顯示操作提示氣泡")

        self.check_smart = QCheckBox("啟用智慧配對")
        self.check_smart.setChecked(True)
        self.check_smart.setToolTip("開啟後，拖曳資料夾時會自動尋找 README.md")

        self.check_guidance.toggled.connect(self._on_pref_changed)
        self.check_smart.toggled.connect(self._on_pref_changed)

        pref_layout.addWidget(self.check_guidance)
        pref_layout.addWidget(self.check_smart)
        pref_layout.addStretch(1)

        left_panel.addLayout(pref_layout)

        # --- 臨時資料夾拖入區（S-02-03 / UI 骨架）---
        self.preview_drop_frame = PreviewDropFrame(self._on_preview_folder_dropped)
        self.preview_drop_frame.setObjectName("previewDropFrame")
        self.preview_drop_frame.setFrameShape(QFrame.Shape.StyledPanel)
        self.preview_drop_frame.setMinimumHeight(180)
        self.preview_drop_frame.setStyleSheet("""
            QFrame#previewDropFrame {
                border: 2px dashed #cc4444;
                border-radius: 8px;
                background-color: #fffdfd;
            }
        """)

        preview_drop_layout = QVBoxLayout(self.preview_drop_frame)
        preview_drop_layout.setContentsMargins(12, 12, 12, 12)
        preview_drop_layout.setSpacing(8)

        self.preview_drop_title = QLabel("臨時資料夾拖入區")
        self.preview_drop_title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.preview_drop_title.setStyleSheet("font-weight: bold; color: #cc2222;")

        self.preview_drop_hint = QLabel("📂 Drop Folder\n\n拖入資料夾即可預覽並複製目錄樹\n（不註冊 / 不監控 / 用完即棄）")
        self.preview_drop_hint.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.preview_drop_hint.setWordWrap(True)
        self.preview_drop_hint.setStyleSheet("color: #aa3333;")

        preview_drop_layout.addWidget(self.preview_drop_title)
        preview_drop_layout.addWidget(self.preview_drop_hint, stretch=1)

        left_panel.addWidget(self.preview_drop_frame)
        left_panel.addStretch(1)

        # 右側：主操作區（按鈕 + 目錄樹工作區）
        right_panel = QVBoxLayout()

        action_layout = QHBoxLayout()

        self.btn_audit_muted = QPushButton("審查靜默/過熱項目…")
        self.btn_audit_muted.clicked.connect(self._open_audit_dialog)

        self.btn_tree_ignore = QPushButton("編輯目錄樹忽略規則…")
        self.btn_tree_ignore.clicked.connect(self._open_ignore_settings_dialog)

        self.btn_sync_write = QPushButton("🔄 同步寫入")
        self.btn_sync_write.setEnabled(False)
        self.btn_sync_write.clicked.connect(self._perform_sync_write_for_current_selection)

        self.btn_copy_tree = QPushButton("複製目錄樹")
        self.btn_copy_tree.clicked.connect(self._copy_current_tree)
        self.btn_copy_tree.setEnabled(False)

        self.btn_audit_muted.setEnabled(False)
        self.btn_tree_ignore.setEnabled(False)

        action_layout.addWidget(self.btn_audit_muted)
        action_layout.addWidget(self.btn_tree_ignore)
        action_layout.addWidget(self.btn_sync_write)
        action_layout.addWidget(self.btn_copy_tree)
        action_layout.addStretch(1)

        right_panel.addLayout(action_layout)

        self.tree_workspace = QFrame()
        self.tree_workspace.setFrameShape(QFrame.Shape.Box)
        self.tree_workspace.setMinimumHeight(0)

        tree_layout = QVBoxLayout(self.tree_workspace)
        tree_layout.setContentsMargins(12, 12, 12, 12)

        tree_splitter = QSplitter(Qt.Orientation.Horizontal, self.tree_workspace)

        self.tree_viewer = QTreeWidget()
        self.tree_viewer.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        self.tree_viewer.setHeaderLabels(["名稱"])
        self.tree_viewer.setColumnCount(1)
        self.tree_viewer.setAlternatingRowColors(True)
        self.tree_viewer.setRootIsDecorated(True)
        self.tree_viewer.setUniformRowHeights(True)
        self.tree_viewer.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAsNeeded)
        self.tree_viewer.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAsNeeded)
        self.tree_viewer.setTextElideMode(Qt.TextElideMode.ElideNone)

        tree_header = self.tree_viewer.header()
        tree_header.setStretchLastSection(True)
        tree_header.setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)

        self.tree_detail_panel = QWidget()
        detail_layout = QVBoxLayout(self.tree_detail_panel)
        detail_layout.setContentsMargins(0, 0, 0, 0)
        detail_layout.setSpacing(8)

        self.tree_meta_viewer = QTextEdit()
        self.tree_meta_viewer.setReadOnly(True)
        self.tree_meta_viewer.setFrameShape(QFrame.Shape.StyledPanel)
        self.tree_meta_viewer.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAsNeeded)
        self.tree_meta_viewer.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAsNeeded)
        self.tree_meta_viewer.setPlaceholderText("選取目錄樹節點後，會在這裡顯示系統資訊。")
        self.tree_meta_viewer.setPlainText("節點資訊區：\n請先選取左側專案，並點選目錄樹節點。")

        self.tree_comment_editor = QTextEdit()
        self.tree_comment_editor.setReadOnly(False)
        self.tree_comment_editor.setFrameShape(QFrame.Shape.StyledPanel)
        self.tree_comment_editor.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAsNeeded)
        self.tree_comment_editor.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAsNeeded)
        self.tree_comment_editor.setPlaceholderText("可在這裡編輯目前節點的註解。")
        self.tree_comment_editor.setPlainText("請先選取左側專案，並點選目錄樹節點。")

        detail_layout.addWidget(QLabel("<b>節點資訊</b>"))
        detail_layout.addWidget(self.tree_meta_viewer, stretch=3)
        detail_layout.addWidget(QLabel("<b>註解編輯</b>"))
        detail_layout.addWidget(self.tree_comment_editor, stretch=2)

        placeholder_item = QTreeWidgetItem(["目錄樹工作區"])
        placeholder_item.setData(0, Qt.ItemDataRole.UserRole, {
            "comment": "選取左側某個專案後，會在這裡顯示目錄樹。",
            "path_key": "",
            "is_dir": True,
        })
        self.tree_viewer.addTopLevelItem(placeholder_item)
        self.tree_viewer.expandAll()

        tree_splitter.addWidget(self.tree_viewer)
        tree_splitter.addWidget(self.tree_detail_panel)
        tree_splitter.setStretchFactor(0, 3)
        tree_splitter.setStretchFactor(1, 2)

        tree_layout.addWidget(tree_splitter)

        right_panel.addWidget(self.tree_workspace, stretch=1)

        # --- 組合佈局 ---
        layout.addLayout(right_panel, stretch=4)
        layout.addLayout(left_panel, stretch=1)

        # 回傳（return）設定好的框架元件。
        return frame

    def _on_preview_folder_dropped(self, folder_path: str) -> None:
        """S-02-03：拖入資料夾後，顯示臨時 preview tree。"""
        self._enter_preview_tree_mode()

        if hasattr(self, "preview_drop_hint"):
            self.preview_drop_hint.setText(f"已接收資料夾\n\n{folder_path}")

        try:
            preview_payload = adapter.preview_tree_from_path(folder_path)
            tree_only = preview_payload.get("tree", {})

            self.tree_viewer.clear()

            if isinstance(tree_only, dict) and tree_only:
                self._current_tree_payload = tree_only
                self._populate_tree_widget(tree_only)
                self.tree_viewer.expandToDepth(1)

                first_item = self.tree_viewer.topLevelItem(0)
                if first_item is not None:
                    self.tree_viewer.setCurrentItem(first_item)
                    self._on_tree_item_changed(first_item)

                if hasattr(self, 'btn_copy_tree'):
                    self.btn_copy_tree.setEnabled(True)

                if hasattr(self, 'btn_sync_write'):
                    self.btn_sync_write.setEnabled(False)

                if hasattr(self, 'btn_tree_ignore'):
                    self.btn_tree_ignore.setEnabled(False)

                if hasattr(self, 'btn_audit_muted'):
                    self.btn_audit_muted.setEnabled(False)

                self._set_status_message("已載入臨時預覽樹，可直接複製目錄樹。", level="success")
            else:
                self._show_tree_placeholder()
                self._set_status_message("臨時預覽失敗：後端未回傳有效目錄樹。", level="error")

        except Exception as e:
            self._set_status_message(f"臨時預覽失敗：{e}", level="error")

    def _on_pref_changed(self):
        """[Task 9.4] 當 Checkbox 變更時，儲存設定並發送訊號"""
        g = self.check_guidance.isChecked()
        s = self.check_smart.isChecked()
        
        # [Task 9.4-Memory] 寫入記憶
        if hasattr(self, 'settings'):
            self.settings.setValue("enable_guidance", g)
            self.settings.setValue("enable_smart_match", s)
            
        # 發射訊號
        self.preferences_changed.emit(g, s)

    # ---------------------------
    # 從 backend_adapter 載入資料
    # ---------------------------

    def _reload_projects_from_backend(self) -> None:
        """呼叫 adapter.list_projects()，並刷新表格內容 (訊號屏蔽版)。"""
        # 1. 獲取資料
        self.current_projects = adapter.list_projects()
        
        # 2. 更新統計與 Tooltip
        self._notify_stats_update()

        # [關鍵修正] 暫時切斷表格的訊號，避免更新過程觸發不必要的 selectionChanged
        self.project_table.blockSignals(True)
        
        try:
            self.project_table.setRowCount(len(self.current_projects))
            
            for row, proj in enumerate(self.current_projects):
                # 1. UUID (隱藏)
                uuid_item = QTableWidgetItem(proj.uuid)
                uuid_item.setFlags(uuid_item.flags() & ~Qt.ItemFlag.ItemIsEditable)
                self.project_table.setItem(row, 0, uuid_item)

                # 2. 名稱
                name_item = QTableWidgetItem(proj.name)
                name_item.setFlags(name_item.flags() & ~Qt.ItemFlag.ItemIsEditable)
                self.project_table.setItem(row, 1, name_item)

                # 3. 狀態 (改為眼睛按鈕)
                # 我們建立一個容器 widget 來置中按鈕
                btn_widget = QWidget()
                btn_layout = QHBoxLayout(btn_widget)
                btn_layout.setContentsMargins(0, 0, 0, 0)
                btn_layout.setAlignment(Qt.AlignmentFlag.AlignCenter)
                
                is_running = (proj.status == "monitoring")
                # [UX 優化] 圖文並茂：讓狀態一目了然
                icon_text = " 監控中 👁️ " if is_running else " 已停止 💤 "
                btn_style = """
                    QPushButton { border: none; font-size: 14px; background: transparent; font-weight: bold; }
                    QPushButton:hover { background-color: #EEEEEE; border-radius: 4px; }
                """
                if is_running:
                    btn_style += "QPushButton { color: #00AA00; }" # 綠眼
                else:
                    btn_style += "QPushButton { color: #888888; }" # 灰眼

                btn_eye = QPushButton(icon_text)
                btn_eye.setCursor(Qt.CursorShape.PointingHandCursor)
                btn_eye.setStyleSheet(btn_style)
                btn_eye.setToolTip("點擊切換：啟動/停止監控")
                
                # 綁定點擊事件 (使用 lambda 鎖定當下的 uuid)
                # 注意：這裡我們直接呼叫 _on_project_double_clicked 裡面的核心邏輯
                # 但為了方便，我們稍後會新增一個專用的 _toggle_by_uuid 函式
                btn_eye.clicked.connect(lambda checked, u=proj.uuid: self._toggle_by_uuid(u))
                
                btn_layout.addWidget(btn_eye)
                self.project_table.setCellWidget(row, 2, btn_widget)

                # 4. 模式
                mode_item = QTableWidgetItem(self._mode_to_label(proj.mode))
                mode_item.setFlags(mode_item.flags() & ~Qt.ItemFlag.ItemIsEditable)
                self.project_table.setItem(row, 3, mode_item)

            # [關鍵修正] 資料填完後，手動處理選取狀態
            if self.current_projects:
                # 預設選取第一行 (或者您可以改成保持之前的選取，但選第一行最穩)
                self.project_table.selectRow(0)
                
                # 手動更新詳情面板 (因為訊號被切斷了，必須手動呼叫)
                self._update_detail_panel(self.current_projects[0])

                if hasattr(self, 'btn_sync_write'):
                    self.btn_sync_write.setEnabled(True)
            else:
                self._update_detail_panel(None)

                if hasattr(self, 'btn_sync_write'):
                    self.btn_sync_write.setEnabled(False)
                
        finally:
            # [關鍵修正] 無論如何，最後一定要把訊號接回去，不然使用者就不能點擊了
            self.project_table.blockSignals(False)

    def _refresh_current_log(self):
        """[自動呼叫] 刷新當前選中專案的日誌"""
        # 如果視窗沒顯示，就不用浪費效能去抓
        if not self.isVisible():
            return

        # 獲取當前選中的行
        row = self.project_table.currentRow()
        if row < 0 or row >= len(self.current_projects):
            return

        # 獲取 UUID
        proj = self.current_projects[row]
        
        # 呼叫 Adapter 獲取最新日誌
        logs = adapter.get_log_content(proj.uuid)
        
        # 更新顯示 (LogViewerWidget 會自動處理捲動)
        if hasattr(self, 'log_viewer'):
            self.log_viewer.set_logs(logs)

    def _open_audit_dialog(self) -> None:
        """[Task 9.4] 審查靜默項目 (Audit)"""
        # 1. 防呆：確認有選到專案
        row = self.project_table.currentRow()
        if row < 0 or row >= len(self.current_projects):
            return
        
        proj = self.current_projects[row]
        
        self._set_status_message(f"正在查詢專案 '{proj.name}' 的靜默狀態...", level="info")
        # 讓介面轉圈圈，避免卡頓感
        QApplication.processEvents()

        try:
            # 2. 呼叫 Adapter 查詢 (注意：這個方法我們等一下才要在 adapter.py 補上！)
            muted_paths = adapter.get_muted_paths(proj.uuid)
            
            if not muted_paths:
                QMessageBox.information(self, "審查結果", "目前沒有被靜默的路徑，一切正常。")
                self._set_status_message("審查完成：無異常。", level="success")
                return

            # 3. 構建詢問訊息
            msg = "發現以下路徑因頻繁變動已被暫時靜默：\n\n"
            # 只顯示前 10 行，避免視窗爆炸
            msg += "\n".join(muted_paths[:10]) 
            if len(muted_paths) > 10:
                msg += f"\n... 以及其他 {len(muted_paths)-10} 個"
            msg += "\n\n是否將它們「固化」到忽略清單中？(這將永久忽略它們)"

            # 4. 彈出對話框
            reply = QMessageBox.question(self, "發現靜默項目", msg, QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No)
            
            if reply == QMessageBox.StandardButton.Yes:
                # 5. 確認後呼叫 Adapter 執行固化 (這個方法我們等一下也要補！)
                adapter.solidify_ignore_patterns(proj.uuid)
                
                self._set_status_message(f"✓ 已固化忽略規則。", level="success")
                QMessageBox.information(self, "成功", "已更新忽略規則，哨兵將自動重啟。")
                
                # 6. 刷新介面
                self._reload_projects_from_backend()
            else:
                self._set_status_message("已取消審查操作。", level="info")

        except Exception as e:
            self._set_status_message(f"審查失敗：{e}", level="error")
            QMessageBox.critical(self, "錯誤", f"無法執行審查：\n{e}")

    def _open_ignore_settings_dialog(self) -> None:
        """打開忽略規則設定視窗"""
        # 1. 獲取當前選中的專案
        row = self.project_table.currentRow()
        if row < 0 or row >= len(self.current_projects):
            return
        
        proj = self.current_projects[row]
        
        self._set_status_message(f"正在讀取專案 '{proj.name}' 的忽略設定...", level="info")
        # 強制刷新 UI，避免卡頓感
        QApplication.processEvents()

        try:
            # 2. 從後端讀取兩份資料：候選名單 & 當前設定
            candidates = adapter.get_ignore_candidates(proj.uuid)
            current_patterns = set(adapter.get_current_ignore_patterns(proj.uuid))
            
            # 3. 建立並顯示對話框
            dialog = IgnoreSettingsDialog(self, proj.name)
            
            # 將資料載入對話框，讓它正確顯示勾選狀態
            dialog.load_patterns(candidates, current=current_patterns)
            
            # 4. 等待使用者操作
            if dialog.exec() == QDialog.DialogCode.Accepted:
                # 使用者按了儲存，獲取最新的勾選結果
                new_patterns = dialog.get_result()
                
                self._set_status_message(f"正在儲存設定並重啟哨兵...", level="info")
                QApplication.processEvents()
                
                # 5. 呼叫後端寫入
                adapter.update_ignore_patterns(proj.uuid, new_patterns)
                
                self._set_status_message(f"✓ 專案 '{proj.name}' 忽略規則已更新。", level="success")
                QMessageBox.information(self, "更新成功", "忽略規則已更新，哨兵已自動重啟以套用新設定。")
            else:
                # 使用者按取消
                self._set_status_message("已取消編輯忽略規則。", level="info")

        except Exception as e:
            self._set_status_message(f"讀取/儲存設定失敗：{e}", level="error")
            QMessageBox.critical(self, "錯誤", str(e))

# 這裡，我們用「def」來定義（define）載入忽略設定的函式。
    def _load_ignore_settings(self) -> None:
        """從 adapter 取得忽略設定，顯示在底部文字區。"""
        # 呼叫（call）後端（adapter）的 get_ignore_settings 函式，獲取忽略設定物件。
        settings = adapter.get_ignore_settings()
        
        # 建立（[]）一個叫 text_lines 的「文字籃子」，準備好要顯示的每一行文字。
        text_lines = [
            "忽略設定區（暫時版）：",
            "",
            # 這是 f-string 的寫法，用於組裝文字。
            # .join(settings.sentry_ignore_patterns) 會把忽略樣式用逗號連接起來。
            f"- 哨兵忽略樣式：{', '.join(settings.sentry_ignore_patterns) or '(無)'}",
            # 顯示目錄樹的深度限制。
            f"- 目錄樹深度限制：{settings.tree_depth_limit}",
        ]
        # 用換行符號（\n）將「文字籃子」中的每一行文字連接（join）起來，
        # 然後設定（setText）到忽略資訊標籤（ignore_info_label）上。
        self.ignore_info_label.setText("\n".join(text_lines))


    # 這裡，我們用「def」來定義（define）更新底部狀態訊息的函式。
    def _set_status_message(self, text: str, level: str = "info") -> None:
        """
        更新底部狀態訊息列。
        
        level:
            - "info"    一般訊息（灰色）
            - "success" 成功訊息（綠色）
            - "error"   錯誤訊息（紅色）
        """
        # .strip() 是去除文字前後的空格。
        # 如果（or）輸入的 text 是空字串，就用預設文字「狀態訊息：」來代替。
        text = text.strip() or "狀態訊息："

        # 用「if」來判斷（if）：如果 level 是 "error"（錯誤）...
        if level == "error":
            # 顏色就設定為紅色（#aa0000）。
            color = "#aa0000"
        # 用「elif」來判斷（else if）：否則，如果 level 是 "success"（成功）...
        elif level == "success":
            # 顏色就設定為綠色（#006600）。
            color = "#006600"
        # 用「else」來判斷：都不是的話（預設是 "info"）...
        else:
            # 顏色就設定為灰色（#666666）。
            color = "#666666"

        # 設定（setText）狀態訊息標籤的文字。
        self.status_message_label.setText(text)
        # 設定（setStyleSheet）標籤的樣式，把前面判斷好的顏色放進去。
        self.status_message_label.setStyleSheet(f"color: {color};")

    def _enter_preview_tree_mode(self) -> None:
        """切換到臨時 preview tree 模式，並清空正式寫入上下文。"""
        self._is_preview_tree_mode = True
        self._reset_tree_edit_context()

        if hasattr(self, "tree_comment_editor"):
            self.tree_comment_editor.setReadOnly(True)
            self.tree_comment_editor.setPlaceholderText("臨時預覽模式不可編輯註解。")
            self._load_tree_comment_into_editor("【臨時預覽模式】\n此區僅供查看，不可編輯註解，也不可同步寫入正式專案。")

    def _enter_project_tree_mode(self) -> None:
        """切換回正式專案樹模式。"""
        self._is_preview_tree_mode = False

        if hasattr(self, "tree_comment_editor"):
            self.tree_comment_editor.setReadOnly(False)
            self.tree_comment_editor.setPlaceholderText("可在這裡編輯目前節點的註解。")

    def _reset_tree_edit_context(self) -> None:
        """清空目前樹節點的註解編輯上下文。"""
        self._current_tree_project_uuid = ""
        self._current_tree_path_key = ""
        self._current_tree_original_comment = ""
        self._current_tree_dirty = False
        self._refresh_tree_sync_button_state()

    def _load_tree_comment_into_editor(self, comment_text: str) -> None:
        """以受控方式把註解載入 editor，避免誤觸 dirty。"""
        self._is_loading_tree_comment = True
        try:
            self.tree_comment_editor.setPlainText(comment_text)
        finally:
            self._is_loading_tree_comment = False

    def _refresh_tree_sync_button_state(self) -> None:
        """依目前節點上下文與 dirty 狀態更新同步/發布按鈕可用性。"""
        if not hasattr(self, "btn_sync_write"):
            return

        if self._is_preview_tree_mode:
            self.btn_sync_write.setEnabled(False)
            self.btn_sync_write.setText("🔄 同步寫入")
            return

        has_project = bool(self._current_tree_project_uuid)
        has_path_key = bool(self._current_tree_path_key)
        can_sync = has_project and has_path_key and self._current_tree_dirty

        current_project = next(
            (p for p in self.current_projects if p.uuid == self._current_tree_project_uuid),
            None
        )
        has_publish_targets = bool(current_project and len(current_project.output_file) > 1)

        self.btn_sync_write.setEnabled(can_sync or has_publish_targets)

        if can_sync:
            self.btn_sync_write.setText("🔄 同步寫入 *")
        elif has_publish_targets:
            self.btn_sync_write.setText("📢 發布")
        else:
            self.btn_sync_write.setText("🔄 同步寫入")

    def _on_tree_comment_text_changed(self) -> None:
        """當註解正文被編輯時，更新 dirty 狀態。"""
        if self._is_loading_tree_comment:
            return

        current_text = self.tree_comment_editor.toPlainText()
        self._current_tree_dirty = (current_text != self._current_tree_original_comment)
        self._refresh_tree_sync_button_state()

    # ---------------------------
    # 事件處理：選取、雙擊
    # ---------------------------

# 這裡，我們用「def」來定義（define）當專案列表的選取項目改變時（selection_changed）執行的函式。
    def _tree_to_plaintext_lines(
        self,
        node: Dict[str, Any],
        prefix: str = "",
        is_last: bool = True,
        is_root: bool = True,
    ) -> List[str]:
        """把樹資料轉成可複製的純文字樹（含樹枝符號）。"""
        if not isinstance(node, dict):
            return []

        name = str(node.get("name", ""))
        comment = str(node.get("comment", "") or "")

        if is_root:
            line = name
            child_prefix = ""
        else:
            branch = "└── " if is_last else "├── "
            line = f"{prefix}{branch}{name}"
            child_prefix = prefix + ("    " if is_last else "│   ")

        if comment:
            line = f"{line}    # {comment}"

        lines = [line]

        children = node.get("children", [])
        if isinstance(children, list):
            valid_children = [child for child in children if isinstance(child, dict)]
            for index, child in enumerate(valid_children):
                child_is_last = (index == len(valid_children) - 1)
                lines.extend(
                    self._tree_to_plaintext_lines(
                        child,
                        prefix=child_prefix,
                        is_last=child_is_last,
                        is_root=False,
                    )
                )

        return lines

    def _copy_current_tree(self) -> None:
        """複製目前選取節點的子樹；若未選到有效節點則複製整個專案樹。"""
        tree_payload = getattr(self, "_current_tree_payload", None)
        if not isinstance(tree_payload, dict) or not tree_payload:
            self._set_status_message("目前沒有可複製的目錄樹。", level="error")
            return

        current_item = self.tree_viewer.currentItem() if hasattr(self, "tree_viewer") else None
        selected_node: Dict[str, Any] | None = None
        copy_scope_label = "資料夾目錄樹" if getattr(self, "_is_preview_tree_mode", False) else "整個專案樹"

        if current_item is not None:
            payload = current_item.data(0, Qt.ItemDataRole.UserRole)
            if isinstance(payload, dict):
                tree_node = payload.get("tree_node")
                if isinstance(tree_node, dict) and tree_node:
                    selected_node = tree_node

                    selected_path_key = str(payload.get("path_key", "") or "").strip()
                    if selected_path_key in ("", "(root)"):
                        copy_scope_label = "資料夾目錄樹" if getattr(self, "_is_preview_tree_mode", False) else "整個專案樹"
                    else:
                        copy_scope_label = f"目前選取節點子樹：{selected_path_key}"

        if selected_node is None:
            selected_node = tree_payload

        lines = self._tree_to_plaintext_lines(selected_node)
        text = "\n".join(lines).strip()

        if not text:
            self._set_status_message("目前沒有可複製的目錄樹內容。", level="error")
            return

        QApplication.clipboard().setText(text)
        self._set_status_message(f"✓ 已複製：{copy_scope_label}", level="success")

    def _find_tree_item_by_path_key(self, path_key: str) -> QTreeWidgetItem | None:
        """在目前樹上依 path_key 找回對應節點。"""
        if not hasattr(self, "tree_viewer"):
            return None

        normalized_target = "" if path_key in ("", "(root)") else str(path_key or "").strip()

        def _walk(item: QTreeWidgetItem) -> QTreeWidgetItem | None:
            payload = item.data(0, Qt.ItemDataRole.UserRole)
            if isinstance(payload, dict):
                raw_path_key = str(payload.get("path_key", "") or "").strip()
                normalized_item_key = "" if raw_path_key in ("", "(root)") else raw_path_key
                if normalized_item_key == normalized_target:
                    return item

            for i in range(item.childCount()):
                child_item = item.child(i)
                if child_item is None:
                    continue

                found = _walk(child_item)
                if found is not None:
                    return found

            return None

        for i in range(self.tree_viewer.topLevelItemCount()):
            top_item = self.tree_viewer.topLevelItem(i)
            if top_item is None:
                continue

            found = _walk(top_item)
            if found is not None:
                return found

        return None

    def _populate_tree_widget(self, node: Dict[str, Any], parent_item: QTreeWidgetItem | None = None) -> None:
        """把後端回傳的巢狀 tree JSON 轉成 QTreeWidgetItem。"""
        if not isinstance(node, dict):
            return

        name = str(node.get("name", ""))
        comment = node.get("comment")
        comment_text = "" if comment is None else str(comment)
        comment_exists = bool(node.get("comment_exists", False))
        path_key = str(node.get("path_key", ""))
        is_dir = bool(node.get("is_dir", False))

        display_name = name if comment_exists else f"⚠ {name}"

        item = QTreeWidgetItem([display_name])
        item.setData(0, Qt.ItemDataRole.UserRole, {
            "comment": comment_text,
            "comment_exists": comment_exists,
            "path_key": path_key,
            "is_dir": is_dir,
            "tree_node": node,
            "project_uuid": self._current_tree_project_uuid if not self._is_preview_tree_mode else "",
        })

        if parent_item is None:
            self.tree_viewer.addTopLevelItem(item)
        else:
            parent_item.addChild(item)

        children = node.get("children", [])
        if isinstance(children, list):
            for child in children:
                if isinstance(child, dict):
                    self._populate_tree_widget(child, item)

    def _show_tree_placeholder(self) -> None:
        """恢復目錄樹工作區的預設提示。"""
        self.tree_viewer.clear()
        self._current_tree_payload = None
        self._reset_tree_edit_context()

        placeholder_item = QTreeWidgetItem(["目錄樹工作區"])
        placeholder_item.setData(0, Qt.ItemDataRole.UserRole, {
            "comment": "選取左側某個專案後，會在這裡顯示目錄樹。",
            "path_key": "",
            "is_dir": True,
            "tree_node": None,
        })
        self.tree_viewer.addTopLevelItem(placeholder_item)
        self.tree_viewer.expandAll()

        if hasattr(self, 'tree_meta_viewer'):
            self.tree_meta_viewer.setPlainText("節點資訊區：\n請先選取左側專案，並點選目錄樹節點。")

        if hasattr(self, 'tree_comment_editor'):
            self._load_tree_comment_into_editor("請先選取左側專案，並點選目錄樹節點。")

        if hasattr(self, 'btn_copy_tree'):
            self.btn_copy_tree.setEnabled(False)

    def _on_tree_item_changed(self, current: QTreeWidgetItem | None, previous: QTreeWidgetItem | None = None) -> None:
        """當使用者點選樹節點時，更新右側節點資訊與註解編輯區。"""
        if not hasattr(self, 'tree_meta_viewer') or not hasattr(self, 'tree_comment_editor'):
            return

        if current is None:
            self._reset_tree_edit_context()
            self.tree_meta_viewer.setPlainText("節點資訊區：\n請先選取左側專案，並點選目錄樹節點。")
            self._load_tree_comment_into_editor("請先選取左側專案，並點選目錄樹節點。")
            return

        payload = current.data(0, Qt.ItemDataRole.UserRole)
        if not isinstance(payload, dict):
            self._reset_tree_edit_context()
            self.tree_meta_viewer.setPlainText("此節點沒有可顯示的系統資訊。")
            self._load_tree_comment_into_editor("")
            return

        name = current.text(0)
        raw_comment = payload.get("comment", "")
        comment_text = "" if raw_comment is None else str(raw_comment)
        raw_path_key = str(payload.get("path_key", "") or "").strip()
        is_dir = bool(payload.get("is_dir", False))

        is_root_node = raw_path_key in ("", "(root)")
        if is_root_node:
            path_key = "(root)"
            if getattr(self, "_is_preview_tree_mode", False):
                node_type = "資料夾根目錄"
                copy_scope = "資料夾目錄樹"
                source_label = "目前複製來源：整個資料夾目錄"
            else:
                node_type = "專案根資料夾"
                copy_scope = "整個專案樹"
                source_label = "目前複製來源：整個專案根目錄"
        else:
            normalized_path_key = raw_path_key.rstrip("/") if is_dir else raw_path_key
            path_key = normalized_path_key
            node_type = "資料夾" if is_dir else "檔案"
            copy_scope = f"此節點子樹：{path_key}"
            source_label = f"目前複製來源：{path_key}"

        current_project_uuid = str(payload.get("project_uuid", "") or "").strip()

        self._current_tree_project_uuid = current_project_uuid
        self._current_tree_path_key = path_key
        self._current_tree_original_comment = comment_text
        self._current_tree_dirty = False

        detail_lines = [
            f"名稱：{name}",
            f"類型：{node_type}",
            f"路徑鍵：{path_key}",
            source_label,
            f"按下「複製目錄樹」時：會複製 {copy_scope}",
        ]
        self.tree_meta_viewer.setPlainText("\n".join(detail_lines))
        self._load_tree_comment_into_editor(comment_text)
        self._refresh_tree_sync_button_state()

    def _on_project_selection_changed(self) -> None:
        # 獲取（get）目前選取的行號（currentRow）。
        row = self.project_table.currentRow()
        
        # 用「if」來判斷：如果（if）行號小於 0（沒選取）...
        if row < 0 or row >= len(self.current_projects):
            self._update_detail_panel(None)
            self.btn_tree_ignore.setEnabled(False)
            self.btn_audit_muted.setEnabled(False)
            if hasattr(self, 'btn_sync_write'):
                self.btn_sync_write.setEnabled(False)
            if hasattr(self, 'btn_copy_tree'):
                self.btn_copy_tree.setEnabled(False)
            # [New] 清空日誌
            if hasattr(self, 'log_viewer'):
                self.log_viewer.set_logs([])
            if hasattr(self, 'tree_viewer'):
                self._show_tree_placeholder()
            return

        self._enter_project_tree_mode()

        # 從「專案籃子」（self.current_projects）中，根據行號（row）取出選取的專案（proj）。
        proj = self.current_projects[row]
        # 呼叫（call）_update_detail_panel 函式，顯示這個專案的詳細資訊。
        self._update_detail_panel(proj)

        # 有選到專案，啟用按鈕
        self.btn_tree_ignore.setEnabled(True)
        self.btn_audit_muted.setEnabled(True)
        if hasattr(self, 'btn_sync_write'):
            self.btn_sync_write.setEnabled(True)

        # [New] 讀取並顯示日誌
        logs = adapter.get_log_content(proj.uuid)
        self.log_viewer.set_logs(logs)

        # [R-02-02] 讀取並顯示結構化目錄樹
        tree_payload = adapter.get_project_tree(proj.uuid)
        tree_only = tree_payload.get("tree", {})

        self.tree_viewer.clear()
        if isinstance(tree_only, dict) and tree_only:
            self._current_tree_payload = tree_only
            self._current_tree_project_uuid = proj.uuid
            if hasattr(self, 'btn_copy_tree'):
                self.btn_copy_tree.setEnabled(True)

            self._populate_tree_widget(tree_only)
            self.tree_viewer.expandToDepth(1)

            first_item = self.tree_viewer.topLevelItem(0)
            if first_item is not None:
                self.tree_viewer.setCurrentItem(first_item)
                self._on_tree_item_changed(first_item)
        else:
            self._show_tree_placeholder()
    
    # 這裡，我們用「def」來定義（define）當專案列表被雙擊時（double_clicked）執行的函式。
    def _on_project_double_clicked(self) -> None:
        """雙擊列 → 切換監控狀態。"""

        # 1. 先確認有選到有效列
        # 獲取（get）目前選取的行號（currentRow）。
        row = self.project_table.currentRow()
        # 用「if」來判斷：如果（if）行號無效，就直接用「return」結束。
        if row < 0 or row >= len(self.current_projects):
            return

        # 2. 取得 UUID 欄位（第 0 欄是隱藏 uuid）
        # 獲取（get）表格中指定行（row）、第 0 欄的項目（item）。
        uuid_item = self.project_table.item(row, 0)
        # 用「if」來判斷：如果（if）這個項目是空的（None），就直接結束。
        if uuid_item is None:
            # 理論上不該發生，代表列表初始化有問題
            return

        # 獲取（get）表格項目的文字（text），並去除空格（strip）。
        project_key = uuid_item.text().strip()
        # 用「if」來判斷：如果（if）UUID 是空的，就直接結束。
        if not project_key:
            return

        # 3. 呼叫 backend_adapter 切換狀態
        # 呼叫（call）後端（adapter）的 toggle_project_status 函式，嘗試切換專案狀態。
        updated = adapter.toggle_project_status(project_key)
        # 用「if」來判斷：如果（if）回傳的結果是 None（代表切換失敗，找不到專案）...
        if updated is None:
            # D-2：失敗 → 用底部訊息列顯示錯誤（紅字）
            # 呼叫（call）_set_status_message，顯示錯誤訊息，並設定 level 為 "error"。
            self._set_status_message("切換監控狀態失敗：找不到指定專案。", level="error")
            # 用「return」結束。
            return

        # 4. 更新本地快取
        # 用新的更新後的專案物件（updated）替換掉「專案籃子」（self.current_projects）中原本位置的舊物件。
        self.current_projects[row] = updated

        # 【關鍵修復】狀態改變了，這裡一定要重新算一次人頭！
        self._notify_stats_update()

        # 5. 更新表格顯示（狀態 & 模式）
        # 獲取（get）表格中指定行（row）的狀態（第 2 欄）和模式（第 3 欄）項目。
        status_item = self.project_table.item(row, 2)
        mode_item = self.project_table.item(row, 3)

        # 用「if」來判斷：如果（if）狀態項目不是空的...
        if status_item is not None:
            # 就設定（setText）新的狀態文字（這裡呼叫 _status_to_label 轉換中文）。
            status_item.setText(self._status_to_label(updated.status))
        # 用「if」來判斷：如果（if）模式項目不是空的...
        if mode_item is not None:
            # 就設定（setText）新的模式文字（這裡呼叫 _mode_to_label 轉換中文）。
            mode_item.setText(self._mode_to_label(updated.mode))

            # 呼叫（call）_update_detail_panel 函式，用更新後的專案物件（updated）刷新右側詳情面板。
            self._update_detail_panel(updated)

        # 6. D-2：成功 → 同樣用底部訊息列顯示成功（綠字）
        # 呼叫（call）_set_status_message，顯示成功的提示訊息，並設定 level 為 "success"。
        self._set_status_message(
            f"切換監控狀態成功：{updated.name} 現在為 {self._status_to_label(updated.status)}。",
            level="success",
        )

    def _toggle_by_uuid(self, uuid: str) -> None:
        """[UI-4] 通過 UUID 切換專案狀態 (給眼睛按鈕用)"""
        
        # [UX 優化] 1. 先給予即時回饋，避免使用者以為當機
        self._set_status_message("⏳ 正在切換哨兵狀態，請稍候...", level="info")
        # 強制 UI 刷新，讓文字馬上顯示出來，不會被卡住
        QApplication.processEvents()
        
        # 2. 呼叫後端切換 (這裡會卡 1.5 秒，但至少使用者知道我们在做事)
        updated = adapter.toggle_project_status(uuid)
        
        if updated is None:
            self._set_status_message("切換失敗：找不到專案。", level="error")
            return

        # 3. 成功後刷新列表
        self._reload_projects_from_backend()
        
        # 4. 更新詳情
        current_row = self.project_table.currentRow()
        if current_row >= 0 and current_row < len(self.current_projects):
            if self.current_projects[current_row].uuid == uuid:
                self._update_detail_panel(updated)

        self._set_status_message(
            f"狀態已切換：{updated.name} -> {self._status_to_label(updated.status)}", 
            level="success"
        )

    def _on_table_context_menu(self, position) -> None:
        """顯示右鍵選單：支援批次刪除。"""
        # 獲取所有選取的列 (rows)
        selection = self.project_table.selectionModel().selectedRows()
        if not selection:
            return

        menu = QMenu(self.project_table)
        
        # 判斷選取數量
        count = len(selection)
        
        if count == 1:
            # 單選邏輯 (保持原有功能：更新、修改、刪除)
            row = selection[0].row()
            uuid_item = self.project_table.item(row, 0)
            name_item = self.project_table.item(row, 1)
            
            if not uuid_item or not name_item: return
            
            p_uuid = uuid_item.text()
            p_name = name_item.text()

            action_update = QAction("🔄 立即手動更新", menu)
            action_update.triggered.connect(lambda: self._perform_manual_update(p_uuid, p_name))
            menu.addAction(action_update)
            
            menu.addSeparator()
            
            action_edit = QAction("📝 修改專案...", menu)
            action_edit.triggered.connect(lambda: self._perform_edit_project(p_uuid, p_name))
            menu.addAction(action_edit)
            
            menu.addSeparator()
            
            action_delete = QAction("🗑️ 刪除此專案...", menu)
            action_delete.triggered.connect(lambda: self._perform_delete_project([(p_uuid, p_name)]))
            menu.addAction(action_delete)
            
        else:
            # 多選邏輯 (只允許批量刪除，避免邏輯複雜化)
            # 收集所有選取的 (uuid, name)
            targets = []
            for index in selection:
                row = index.row()
                # [修正] 防禦性寫法：先取出 item，檢查是否存在
                item_u = self.project_table.item(row, 0)
                item_n = self.project_table.item(row, 1)
                
                # 只有當兩個格子都有東西時，才取文字
                if item_u and item_n:
                    targets.append((item_u.text(), item_n.text()))
            
            label_text = f"🗑️ 批量刪除 ({count} 個專案)..."
            action_batch_delete = QAction(label_text, menu)
            # 傳遞列表給刪除函式
            action_batch_delete.triggered.connect(lambda: self._perform_delete_project(targets))
            menu.addAction(action_batch_delete)

        menu.exec(self.project_table.viewport().mapToGlobal(position))

    # 這裡，我們用「def」來定義（define）執行手動更新的動作函式。
    def _perform_sync_write_for_current_selection(self) -> None:
        """從工作台入口觸發：有 dirty 時先同步到第一寫入檔；無 dirty 但有多目標時執行發布。"""
        if self._is_preview_tree_mode:
            self._set_status_message("預覽模式不可同步寫入正式專案。", level="info")
            self._refresh_tree_sync_button_state()
            return

        project_uuid = self._current_tree_project_uuid.strip()
        path_key = self._current_tree_path_key
        current_comment = self.tree_comment_editor.toPlainText() if hasattr(self, "tree_comment_editor") else ""

        if not project_uuid:
            self._set_status_message("目前沒有選取任何專案，無法執行。", level="error")
            return

        current_project = next(
            (p for p in self.current_projects if p.uuid == project_uuid),
            None
        )
        has_publish_targets = bool(current_project and len(current_project.output_file) > 1)

        if self._current_tree_dirty:
            if path_key is None:
                self._set_status_message("目前沒有選取任何節點，無法同步寫入。", level="error")
                return

            if hasattr(self, 'btn_sync_write'):
                self.btn_sync_write.setEnabled(False)
                self.btn_sync_write.setText("⏳ 同步中…")

            QApplication.processEvents()

            try:
                adapter.save_tree_comment(project_uuid, path_key, current_comment)

                tree_payload = adapter.get_project_tree(project_uuid)
                tree_only = tree_payload.get("tree", {})

                self.tree_viewer.clear()
                if isinstance(tree_only, dict) and tree_only:
                    self._current_tree_payload = tree_only
                    self._populate_tree_widget(tree_only)
                    self.tree_viewer.expandToDepth(1)

                    target_item = self._find_tree_item_by_path_key(path_key)
                    if target_item is None and self.tree_viewer.topLevelItemCount() > 0:
                        target_item = self.tree_viewer.topLevelItem(0)

                    if target_item is not None:
                        self.tree_viewer.setCurrentItem(target_item)
                        self._on_tree_item_changed(target_item)

                self._set_status_message("✓ 目前節點註解已同步寫入第一寫入檔。", level="success")

            except Exception as e:
                self._current_tree_dirty = True
                self._refresh_tree_sync_button_state()
                self._set_status_message(f"註解同步失敗：{e}", level="error")
            finally:
                if hasattr(self, 'btn_sync_write'):
                    self._refresh_tree_sync_button_state()

            return

        if not has_publish_targets:
            self._set_status_message("目前沒有未同步變更，也沒有可發布的後續寫入檔。", level="info")
            return

        if hasattr(self, 'btn_sync_write'):
            self.btn_sync_write.setEnabled(False)
            self.btn_sync_write.setText("⏳ 發布中…")

        QApplication.processEvents()

        try:
            result = adapter.publish_tree(project_uuid)
            published_count = int(result.get("published_count", 0))
            failed_count = int(result.get("failed_count", 0))

            if failed_count == 0:
                self._set_status_message(f"✓ 已完成發布：{published_count} 個後續寫入檔。", level="success")
            else:
                self._set_status_message(
                    f"發布部分失敗：成功 {published_count} 個，失敗 {failed_count} 個。",
                    level="error",
                )

        except Exception as e:
            self._set_status_message(f"註解發布失敗：{e}", level="error")
        finally:
            if hasattr(self, 'btn_sync_write'):
                self._refresh_tree_sync_button_state()

    def _perform_manual_update(self, uuid: str, name: str) -> None:
        # 先顯示一個「請稍候」的狀態訊息。
        self._set_status_message(f"正在更新專案 '{name}'，請稍候...", level="info")
        
        # 強制刷新（processEvents）UI，避免看起來卡死。
        QApplication.processEvents()

        try:
            # 呼叫（call）後端執行更新。
            adapter.trigger_manual_update(uuid)
            # 成功後顯示綠字訊息。
            self._set_status_message(f"✓ 專案 '{name}' 手動更新成功！", level="success")
            # 彈出成功對話框。
            QMessageBox.information(self, "更新成功", f"專案 '{name}' 的目錄結構已更新至 Markdown。")
        except Exception as e:
            # 失敗顯示紅字訊息。
            self._set_status_message(f"更新失敗：{e}", level="error")
            # 彈出錯誤警告框。
            QMessageBox.critical(self, "更新失敗", str(e))

    def _perform_delete_project(self, targets: list[tuple[str, str]]) -> None:
        """執行刪除專案 (支援單刪與批刪)"""
        count = len(targets)
        if count == 0: return

        # 1. 構建確認訊息
        if count == 1:
            uuid, name = targets[0]
            msg_title = "確認刪除"
            msg_body = f"您確定要刪除專案「{name}」嗎？"
        else:
            names = "\n".join([f"- {t[1]}" for t in targets[:5]]) # 最多顯示前5個名字
            if count > 5: names += "\n...等"
            msg_title = f"確認批量刪除 ({count} 個)"
            msg_body = f"您確定要刪除以下 {count} 個專案嗎？\n\n{names}"

        msg_body += "\n\n這將會停止哨兵並移除設定 (檔案保留)。"

        # 2. 彈出確認
        reply = QMessageBox.question(
            self, msg_title, msg_body,
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No
        )

        if reply != QMessageBox.StandardButton.Yes:
            return

        # 3. 執行刪除循環
        success_count = 0
        errors = []
        
        self._set_status_message(f"正在刪除 {count} 個專案...", level="info")
        QApplication.processEvents()

        for uuid, name in targets:
            try:
                adapter.delete_project(uuid)
                success_count += 1
            except Exception as e:
                errors.append(f"{name}: {str(e)}")

        # 4. 結果回饋與刷新
        self._reload_projects_from_backend()
        self._update_detail_panel(None) # 清空詳情避免殘留

        if len(errors) == 0:
            self._set_status_message(f"✓ 成功刪除 {success_count} 個專案。", level="success")
        else:
            err_msg = "\n".join(errors)
            QMessageBox.critical(self, "部分刪除失敗", f"成功: {success_count}\n失敗: {len(errors)}\n\n錯誤詳情:\n{err_msg}")
            self._set_status_message(f"刪除完成，但有 {len(errors)} 個失敗。", level="error")

# 我們用「def」來定義（define）執行編輯專案函式。
    def _perform_edit_project(self, uuid: str, name: str) -> None:
        """打開編輯視窗，並呼叫後端修改專案。"""

        # 在打開編輯視窗前，強制從後端讀取最新狀態，防止「殘影」
        self._reload_projects_from_backend()

        # 1. 找到專案的完整資料
        target_proj = next((p for p in self.current_projects if p.uuid == uuid), None)
        if not target_proj:
            QMessageBox.critical(self, "錯誤", f"找不到 UUID 為 {uuid} 的專案資料。")
            return

        # 2. 建立並開啟編輯對話框
        dialog = EditProjectDialog(self, target_proj)

        if dialog.exec() == QDialog.DialogCode.Accepted:
            # 3. 獲取所有變動
            changes = dialog.get_changes()
            
            # 檢查即時變更日誌
            logs = dialog.change_log
            
            if not changes and not logs:
                self._set_status_message("沒有任何變更，已取消操作。", level="info")
                return
            
            # 準備成功訊息
            success_msg = "✓ 專案已更新"
            if logs:
                # 將日誌串接起來顯示 (最多顯示 3 筆，太多就省略)
                details = ", ".join(logs[:3])
                if len(logs) > 3: details += f" ...等 {len(logs)} 項"
                success_msg += f" ({details})"
            
            if not changes and logs:
                self._set_status_message(success_msg, level="success")
                self._reload_projects_from_backend()
                return
            
            # 4. 逐一呼叫後端 API 進行修改
            all_success = True
            error_details = []
            
            for field, new_value in changes.items():
                try:
                    if field in ['name', 'path', 'output_file']:
                        self._set_status_message(f"正在修改 '{name}' 的 {field}...", level="info")
                        QApplication.processEvents()
                        
                        # 【修正】這裡改為呼叫 adapter.edit_project(uuid, field, new_value)
                        # 這符合我們剛剛在 adapter.py 定義的接口 (3 個參數)
                        adapter.edit_project(uuid, field, new_value) 
                        
                except Exception as e:
                    all_success = False
                    error_details.append(f"欄位 {field} 失敗：{e}")
                    
            # 5. 根據結果更新 UI
            if all_success:
                self._set_status_message(f"✓ 專案 '{name}' 已成功更新！", level="success")
                self._reload_projects_from_backend() # 重繪列表
            else:
                final_error = "\n".join(error_details)
                self._set_status_message(f"更新失敗！詳情請見彈出視窗。", level="error")
                QMessageBox.critical(self, "部分更新失敗", f"專案 '{name}' 的部分欄位未能更新。\n\n錯誤詳情:\n{final_error}")

    # ---------------------------
    # 詳情區更新
    # ---------------------------

    # 這裡，我們用「def」來定義（define）更新右側詳情面板的函式。
    # 參數 proj 接受一個專案物件（ProjectInfo）或是 None（空值）。
    def _update_detail_panel(
        self,
        proj: adapter.ProjectInfo | None,
    ) -> None:
        # 用「if」來判斷：如果（if）傳入的 proj 是 None（沒有選取專案）...
        if proj is None:
            # 就設定（setText）標籤顯示「尚未選取任何專案。」
            self.detail_label.setText("尚未選取任何專案。")
            # 用「return」結束函式。
            return

        # 呼叫（call）_status_to_label 函式，把狀態代碼（proj.status）轉成中文標籤。
        status_label = self._status_to_label(proj.status)
        # 呼叫（call）_mode_to_label 函式，把模式代碼（proj.mode）轉成中文標籤。
        mode_label = self._mode_to_label(proj.mode)

        # 建立（[]）一個叫 text_lines 的「文字籃子」，用於顯示專案詳情。
        text_lines = [
            f"專案名稱：{proj.name}",
            f"監控狀態：{status_label}",
            f"模式：{mode_label}",
            "",
            f"專案路徑：{proj.path}",
            f"主寫入檔：{proj.output_file[0] if proj.output_file else '(未設定)'}",
        ]
        # 用換行符號（\n）連接（join）文字籃子，並設定（setText）到詳情標籤上。
        self.detail_label.setText("\n".join(text_lines))

    # ---------------------------
    # 標籤轉換（之後可以抽成 i18n）
    # ---------------------------

    # 這裡，我們用「@staticmethod」來標記（mark）這是一個不需要物件（self）就可以呼叫的函式。
    # 它負責把狀態代碼轉成中文標籤。
    @staticmethod
    def _status_to_label(status: str) -> str:
        # 用「return ... if ... else ...」來判斷並回傳（return）中文標籤。
        return "監控中" if status == "monitoring" else "已停止"

    # 這裡，我們用「@staticmethod」來標記（mark）這是一個不需要物件（self）就可以呼叫的函式。
    # 它負責把模式代碼轉成中文標籤。
    @staticmethod
    def _mode_to_label(mode: str) -> str:
        # 用「return ... if ... else ...」來判斷並回傳（return）中文標籤。
        return "靜默" if mode == "silent" else "互動"
    
    # --- Dashboard 模式下不接管整頁拖曳 ---
    # 目前 Dashboard 是一般可縮放視窗，應交由系統標題列負責移動。
    # 這樣才不會搶走 QSplitter 的拖曳事件。
    def mousePressEvent(self, event):
        self.old_pos = None
        super().mousePressEvent(event)

    def mouseMoveEvent(self, event):
        super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event):
        self.old_pos = None
        super().mouseReleaseEvent(event)


# ==========================================
#   View B: 模擬「控制台」 (Dashboard)
# ==========================================
# 我們用「class」來 定義（define）一個模擬的視圖 B。
class MockViewB(QWidget):
    def __init__(self, switch_callback):
        super().__init__()
        # 設定（set）背景為白色，字體為黑色，模擬「控制台」的亮色風格。
        self.setStyleSheet("background-color: white; color: black;")
        
        layout = QVBoxLayout(self)
        
        # 顯示標題
        label = QLabel("View B: 控制台 (Legacy List)")
        label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(label)
        
        # 測試按鈕：返回眼睛
        btn_back = QPushButton("↩ 返回哨兵之眼")
        # 當按鈕被點擊（clicked）時，執行切換回調。
        btn_back.clicked.connect(switch_callback)
        layout.addWidget(btn_back)

# ==========================================
#   主控制器：v2.0 托盤應用程式
# ==========================================
class CurrentPageStackedWidget(QStackedWidget):
    """
    只回報「目前頁面」幾何提示的 QStackedWidget。
    目的：
    - 避免 Dashboard 頁的 minimumSizeHint 汙染 Eye 模式
    - 讓 top-level container 的幾何契約跟著 currentWidget 走
    """
    def sizeHint(self) -> QSize:
        current = self.currentWidget()
        if current is not None:
            hint = current.sizeHint()
            if hint.isValid():
                return hint

            current_size = current.size()
            if current_size.isValid() and current_size.width() > 0 and current_size.height() > 0:
                return current_size

        return QSize(0, 0)

    def minimumSizeHint(self) -> QSize:
        current = self.currentWidget()
        if current is not None:
            hint = current.minimumSizeHint()
            if hint.isValid():
                return hint

        return QSize(0, 0)


class SentryTrayAppV2:
    def update_tooltip(self, running: int, muting: int) -> None:
        """更新托盤圖示的 Tooltip 顯示狀態，並檢查循環依賴。"""
        # [DEFENSE] 檢查 self.tray_icon 是否已經被初始化，防止 Dashboard 在載入時提前呼叫導致 AttributeError。
        if not hasattr(self, 'tray_icon') or self.tray_icon is None:
            return

        # 我們用「if...else」判斷狀態並組合（concatenate）字串。
        if running == 0 and muting == 0:
            msg = "Sentry: 目前無監控"
        else:
            msg = f"Sentry: {running} 個監控中"
            if muting > 0:
                msg += f" / {muting} 個靜默中"
        
        self.tray_icon.setToolTip(msg)
    def __init__(self, app: QApplication):
        self.app = app
        
        # --- 1. 建立托盤圖示 ---
        self.tray_icon = QSystemTrayIcon(self._load_icon(), self.app)
        
        # 建立右鍵選單
        menu = QMenu()
        # 建立「顯示/隱藏」動作
        action_show = QAction("顯示/隱藏視窗", menu)
        action_show.triggered.connect(self.toggle_window)
        menu.addAction(action_show)
        
        # 建立「退出」動作
        action_quit = QAction("退出 Sandbox", menu)
        action_quit.triggered.connect(self.app.quit)
        
        menu.addAction(action_quit)
        self.tray_icon.setContextMenu(menu)
        
        # 左鍵點擊托盤也觸發切換
        self.tray_icon.activated.connect(self._on_tray_activated)
        
        self.tray_icon.show()

        # --- 2. 建立雙視圖容器 ---
        # 我們建立（create）一個堆疊容器，它可以像紙牌一樣切換頁面。
        self.container = CurrentPageStackedWidget()
        self.container.setWindowTitle("Sentry v2.0 Sandbox")
        self.container.resize(900, 600)
        # [UI-Only Phase] 記錄 Dashboard 最近一次尺寸，避免切回後丟失使用者調整結果
        self.dashboard_size = QSize(900, 700)

        self.settings = QSettings("sentry_config.ini", QSettings.Format.IniFormat)
        raw_eye_size = self.settings.value("eye_size", 480)

        if isinstance(raw_eye_size, (int, float)):
            self.eye_size = int(raw_eye_size)
        elif isinstance(raw_eye_size, str) and raw_eye_size.strip().isdigit():
            self.eye_size = int(raw_eye_size.strip())
        else:
            self.eye_size = 480

        # 建立 View A，並傳入切換與關機的函式
        self.view_a = SentryEyeWidget(
            switch_callback=self.go_to_dashboard,
            shutdown_callback=self.app.quit, # [NEW] 將 app.quit 函式傳入給 View A
            eye_size=self.eye_size,
            eye_size_callback=self.set_eye_size,
        )
        # 替換為我們剛剛貼入並改名的 DashboardWidget
        # 這裡我們傳入了 self.go_to_eye 函式作為返回按鈕的回調
        # type: ignore # 【技術鎮壓】忽略 Pylance 對 update_tooltip 的循環依賴警告
        self.view_b = DashboardWidget(
            on_stats_change=lambda r, m: self.update_tooltip(r, m),
            switch_callback=self.go_to_eye,
        )
        # 把視圖加入（addWidget）容器中。
        # 索引 0 = View A
        self.container.addWidget(self.view_a)
        # 索引 1 = View B
        self.container.addWidget(self.view_b)
        # [Task 9.4] 連接 Dashboard 的偏好設定訊號到 Eye
        self.view_b.preferences_changed.connect(self.view_a.set_preferences)

        # [初始化順序修正] 先套用 Eye 視窗所需的透明與無邊框屬性，
        # 再呼叫 go_to_eye()，避免第一次 show() 時透明背景尚未生效。
        self.container.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        # [修改] 移除 WindowStaysOnTopHint，不再強制置頂
        self.container.setWindowFlags(Qt.WindowType.FramelessWindowHint)

        # --- 改成呼叫 go_to_eye() 來初始化 ---
        # 這會同時設定頁面並將視窗縮小為 130x130
        self._debug_geometry("before-initial-go-to-eye")
        self.go_to_eye()

        # FIX: 系統啟動時 View A 不再躲起來，而是立即顯示。
        # 使用 singleShot 確保在事件循環啟動後再執行 show()。
        QTimer.singleShot(100, lambda: self._debug_geometry("before-singleShot-show"))
        QTimer.singleShot(100, lambda: self.container.show())
        QTimer.singleShot(100, lambda: self._debug_geometry("after-singleShot-show"))
        QTimer.singleShot(100, lambda: self.container.activateWindow())
        QTimer.singleShot(100, lambda: self.container.raise_())
        QTimer.singleShot(200, lambda: self._debug_geometry("after-raise-200ms"))

    def _debug_geometry(self, tag: str):
        """統一輸出 Eye / Dashboard 幾何觀測資料。"""
        current = self.container.currentWidget()
        current_name = type(current).__name__ if current is not None else "(none)"
        print(
            f"[GEOM {tag}]",
            "current_index=", self.container.currentIndex(),
            "current_widget=", current_name,
            "container_size=", self.container.size(),
            "container_min=", self.container.minimumSize(),
            "container_min_hint=", self.container.minimumSizeHint(),
            "container_max=", self.container.maximumSize(),
            "container_hint=", self.container.sizeHint(),
            "view_a_size=", self.view_a.size(),
            "view_a_min=", self.view_a.minimumSize(),
            "view_a_min_hint=", self.view_a.minimumSizeHint(),
            "view_a_max=", self.view_a.maximumSize(),
            "view_a_hint=", self.view_a.sizeHint(),
            "view_b_size=", self.view_b.size(),
            "view_b_min=", self.view_b.minimumSize(),
            "view_b_min_hint=", self.view_b.minimumSizeHint(),
            "view_b_max=", self.view_b.maximumSize(),
            "view_b_hint=", self.view_b.sizeHint(),
            "flags=", int(self.container.windowFlags()),
        )

    def go_to_dashboard(self):
        """切換到 View B (展開 + 可拉伸)"""
        # 1. 若目前在 Dashboard，先記住使用者最後一次調整的尺寸
        if self.container.currentIndex() == 1:
            self.dashboard_size = self.container.size()

        # 2. 命令 View B 重新去後端拉取最新資料
        self.view_b._reload_projects_from_backend()

        # 3. 先隱藏，恢復 Dashboard 所需幾何契約，再切頁與設尺寸，最後才顯示
        self.container.hide()
        self.container.setWindowFlags(Qt.WindowType.Window)
        self.container.setMinimumSize(self.view_b.minimumSizeHint())
        self.container.setMaximumSize(QSize(16777215, 16777215))
        self.container.setCurrentIndex(1)
        self.container.resize(self.dashboard_size)
        self.container.show()

        self.container.activateWindow()
        self.container.raise_()

    def go_to_eye(self):
        """切換到 View A (縮微 + 固定眼球視窗)"""
        self._debug_geometry("go-to-eye-start")

        # 1. 離開 Dashboard 前，記住最近一次尺寸
        if self.container.currentIndex() == 1:
            self.dashboard_size = self.container.size()
        self._debug_geometry("go-to-eye-after-save-dashboard-size")

        # 2. 先解除 Dashboard 模式的幾何限制，切到 Eye
        self.container.hide()
        self._debug_geometry("go-to-eye-after-hide")

        self.container.setWindowFlags(Qt.WindowType.FramelessWindowHint)
        self._debug_geometry("go-to-eye-after-set-flags")

        self.container.setMinimumSize(0, 0)
        self._debug_geometry("go-to-eye-after-set-min-0")

        self.container.setMaximumSize(QSize(16777215, 16777215))
        self._debug_geometry("go-to-eye-after-set-max")

        self.container.setCurrentIndex(0)
        self._debug_geometry("go-to-eye-after-set-index-0")

        self.container.setFixedSize(self.eye_size, self.eye_size)
        self._debug_geometry("go-to-eye-after-resize-130")

        self.container.show()
        self._debug_geometry("go-to-eye-after-show")

        # 3. 關鍵：show() 後 Qt 會把視窗重新撐大，所以在 show() 後再鎖一次最終尺寸
        self.container.setFixedSize(self.eye_size, self.eye_size)
        self._debug_geometry("go-to-eye-after-fixed-130")

        self.container.activateWindow()
        self._debug_geometry("go-to-eye-after-activate")

        self.container.raise_()
        self._debug_geometry("go-to-eye-end")

    def set_eye_size(self, size: int) -> None:
        self.eye_size = int(size)
        self.settings.setValue("eye_size", self.eye_size)
        self.view_a.set_eye_size(self.eye_size)

        if self.container.currentIndex() == 0:
            self.container.setFixedSize(self.eye_size, self.eye_size)
            self.container.resize(self.eye_size, self.eye_size)

    def toggle_window(self):
        """切換視窗顯示狀態"""
        if self.container.isVisible():
            self.container.hide()
        else:
            self.container.show()
            self.container.activateWindow()

    def _on_tray_activated(self, reason):
        if reason == QSystemTrayIcon.ActivationReason.Trigger:
            self.toggle_window()

    def _load_icon(self) -> QIcon:
        """從 assets/icons/tray_icon.png 載入圖示"""
        # 我們計算（calculate）專案根目錄位置 (往上找兩層：src -> root)
        root = Path(__file__).resolve().parents[2]
        icon_path = root / "assets" / "icons" / "tray_icon.png"

        # 我們用「if」檢查檔案是否存在
        if icon_path.is_file():
            return QIcon(str(icon_path))
        
        # 如果找不到，回傳系統預設圖示當作備案
        return self.app.style().standardIcon(QStyle.StandardPixmap.SP_ComputerIcon)

# --- 程式進入點 ---
def main():
    app = QApplication(sys.argv)
    # 這是為了確保關閉視窗時不會直接殺死程式 (因為有 Tray)。
    app.setQuitOnLastWindowClosed(False)
    
    # 啟動 v2 沙盒
    sandbox = SentryTrayAppV2(app)
    
    sys.exit(app.exec())

if __name__ == "__main__":
    main()

    #  啟動系統 python -m src.tray.tray_app