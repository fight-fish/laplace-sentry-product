import importlib.util
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch


# 這支測試在做什麼：
#   用最小假介面支架載入前端目錄樹方法，保護 lazy children 的兩個契約。
# 這支測試不做什麼：
#   不啟動真實 UI、不連 WSL、不修改產品語義，也不替代 L3 互動驗證。
# 常改區塊：
#   FrontendLazyTreeContractTests 內兩個契約測項。
# 不要亂動的區塊：
#   ScopedTrayAppLoader 的全域狀態還原；它防止本檔污染同一個 discovery process。


REPO_ROOT = Path(__file__).resolve().parents[1]
FRONTEND_ROOT = REPO_ROOT / "Frontend"
TRAY_APP_PATH = FRONTEND_ROOT / "src" / "tray" / "tray_app.py"
TRAY_APP_TEST_MODULE = "tray_app_under_test"
FAKE_PYSIDE_MODULES = (
    "PySide6",
    "PySide6.QtCore",
    "PySide6.QtGui",
    "PySide6.QtWidgets",
)
SCOPED_MODULES = FAKE_PYSIDE_MODULES + (TRAY_APP_TEST_MODULE,)
MISSING = object()


class DummySignal:
    def connect(self, *args, **kwargs):
        return None

    def emit(self, *args, **kwargs):
        return None


def Signal(*args, **kwargs):
    return DummySignal()


class DummyBase:
    def __init__(self, *args, **kwargs):
        pass

    def __getattr__(self, name):
        def method(*args, **kwargs):
            return None

        return method


class FakeQt:
    class ItemDataRole:
        UserRole = 32

    class WindowType:
        SubWindow = 1
        FramelessWindowHint = 2

    class WidgetAttribute:
        WA_TranslucentBackground = 1
        WA_StyledBackground = 2

    class AlignmentFlag:
        AlignCenter = 1


class FakeItem:
    def __init__(self, labels=None):
        self.labels = list(labels or [])
        self.data_by_role = {}
        self.children = []

    def text(self, column):
        return self.labels[column]

    def setData(self, column, role, value):
        self.data_by_role[(column, role)] = value

    def data(self, column, role):
        return self.data_by_role.get((column, role))

    def addChild(self, child):
        self.children.append(child)

    def takeChildren(self):
        children = self.children
        self.children = []
        return children

    def childCount(self):
        return len(self.children)

    def child(self, index):
        return self.children[index]

    def setIcon(self, *args, **kwargs):
        return None

    def setText(self, column, value):
        while len(self.labels) <= column:
            self.labels.append("")
        self.labels[column] = value


class ScopedTrayAppLoader:
    """在單一測項內載入前端模組，離開時還原被碰過的全域狀態。"""

    def __enter__(self):
        self.original_modules = {name: sys.modules.get(name, MISSING) for name in SCOPED_MODULES}
        self.original_sys_path = list(sys.path)
        self._install_fake_pyside_modules()
        try:
            return self._load_tray_app_module()
        except Exception:
            self.restore()
            raise

    def __exit__(self, exc_type, exc, tb):
        self.restore()
        return False

    def restore(self):
        for name in SCOPED_MODULES:
            original = self.original_modules[name]
            if original is MISSING:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = original
        sys.path[:] = self.original_sys_path

    def _install_fake_pyside_modules(self):
        pyside = types.ModuleType("PySide6")
        qtcore = types.ModuleType("PySide6.QtCore")
        qtgui = types.ModuleType("PySide6.QtGui")
        qtwidgets = types.ModuleType("PySide6.QtWidgets")

        qtcore.Qt = FakeQt
        qtcore.Signal = Signal
        for name in [
            "QPoint",
            "QSize",
            "QTimer",
            "QPropertyAnimation",
            "QEasingCurve",
            "QObject",
            "QThread",
            "QLockFile",
            "QSettings",
        ]:
            setattr(qtcore, name, DummyBase)

        for name in [
            "QIcon",
            "QAction",
            "QPainter",
            "QPen",
            "QColor",
            "QBrush",
            "QRadialGradient",
            "QCursor",
            "QPalette",
            "QPainterPath",
        ]:
            setattr(qtgui, name, DummyBase)

        for name in [
            "QApplication",
            "QWidget",
            "QVBoxLayout",
            "QHBoxLayout",
            "QLabel",
            "QPushButton",
            "QSystemTrayIcon",
            "QMenu",
            "QStyle",
            "QStackedWidget",
            "QMessageBox",
            "QInputDialog",
            "QSpacerItem",
            "QSizePolicy",
            "QTableWidget",
            "QTableWidgetItem",
            "QSplitter",
            "QFrame",
            "QAbstractItemView",
            "QLineEdit",
            "QFileDialog",
            "QListWidgetItem",
            "QListWidget",
            "QDialogButtonBox",
            "QDialog",
            "QCheckBox",
            "QTreeWidget",
            "QHeaderView",
            "QTextEdit",
        ]:
            setattr(qtwidgets, name, DummyBase)
        qtwidgets.QTreeWidgetItem = FakeItem

        sys.modules["PySide6"] = pyside
        sys.modules["PySide6.QtCore"] = qtcore
        sys.modules["PySide6.QtGui"] = qtgui
        sys.modules["PySide6.QtWidgets"] = qtwidgets

    def _load_tray_app_module(self):
        frontend_path = str(FRONTEND_ROOT)
        if frontend_path not in sys.path:
            sys.path.insert(0, frontend_path)

        spec = importlib.util.spec_from_file_location(TRAY_APP_TEST_MODULE, TRAY_APP_PATH)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        module.QTreeWidgetItem = FakeItem
        return module


class FrontendLazyTreeContractTests(unittest.TestCase):
    def load_tray_app_for_test(self):
        loader = ScopedTrayAppLoader()
        tray_app = loader.__enter__()
        self.addCleanup(loader.__exit__, None, None, None)
        return tray_app

    def make_dashboard(self, tray_app):
        dashboard = tray_app.DashboardWidget.__new__(tray_app.DashboardWidget)
        dashboard._is_preview_tree_mode = False
        dashboard._latest_children_request_ids = {}
        dashboard._query_request_seq = 0
        dashboard._active_query_threads = []
        dashboard._active_query_workers = []
        dashboard._node_state_cache = {}
        dashboard._current_tree_project_uuid = "project-1"
        dashboard._status_icon_path = lambda *args, **kwargs: ""
        return dashboard

    def test_expanding_same_unloaded_folder_starts_only_one_children_query(self):
        tray_app = self.load_tray_app_for_test()
        dashboard = self.make_dashboard(tray_app)
        started_queries = []

        def start_project_query(query_kind, project_uuid, query_func):
            started_queries.append((query_kind, project_uuid, query_func(project_uuid)))

        dashboard._start_project_query = start_project_query
        fake_children_response = {
            "uuid": "project-1",
            "parent_path_key": "src/",
            "children": [],
            "parent": {"depth_limited": False},
        }
        with patch.object(tray_app.adapter, "get_tree_children", return_value=fake_children_response):
            item = FakeItem(["src/"])
            item.setData(
                0,
                FakeQt.ItemDataRole.UserRole,
                {
                    "is_dir": True,
                    "has_children": True,
                    "children_loaded": False,
                    "children_loading": False,
                    "project_uuid": "project-1",
                    "path_key": "src/",
                    "tree_node": {"children": []},
                },
            )

            dashboard._on_tree_item_expanded(item)
            dashboard._on_tree_item_expanded(item)

        self.assertEqual(
            len(started_queries),
            1,
            "same unloaded folder must not start duplicate children queries while loading",
        )

    def test_children_payload_replaces_placeholder_instead_of_accumulating_items(self):
        tray_app = self.load_tray_app_for_test()
        dashboard = self.make_dashboard(tray_app)
        dashboard._latest_children_request_ids = {("project-1", "src/"): 7}
        dashboard._set_status_message = lambda *args, **kwargs: None

        parent = FakeItem(["src/"])
        old_placeholder = FakeItem(["舊占位"])
        parent.addChild(old_placeholder)
        tree_node = {"children": [{"name": "舊占位"}]}
        payload = {
            "is_dir": True,
            "has_children": True,
            "children_loaded": False,
            "children_loading": True,
            "project_uuid": "project-1",
            "path_key": "src/",
            "tree_node": tree_node,
        }
        parent.setData(0, FakeQt.ItemDataRole.UserRole, payload)
        dashboard._find_tree_item_by_path_key = lambda path_key: parent if path_key == "src/" else None

        result = {
            "uuid": "project-1",
            "parent_path_key": "src/",
            "children": [
                {
                    "name": "core",
                    "path_key": "src/core/",
                    "is_dir": True,
                    "has_children": False,
                    "children_loaded": True,
                    "children": [],
                },
                {
                    "name": "top.txt",
                    "path_key": "src/top.txt",
                    "is_dir": False,
                    "has_children": False,
                    "children_loaded": True,
                    "children": [],
                },
            ],
            "parent": {"depth_limited": False},
        }

        dashboard._apply_tree_children_payload("project-1", "src/", 7, result)

        labels = [parent.child(index).text(0) for index in range(parent.childCount())]
        self.assertEqual(labels, ["core", "top.txt"])
        self.assertEqual(parent.childCount(), 2)
        self.assertTrue(payload["children_loaded"])
        self.assertFalse(payload["children_loading"])
        self.assertEqual(tree_node["children"], result["children"])
        self.assertNotIn(("project-1", "src/"), dashboard._latest_children_request_ids)


if __name__ == "__main__":
    unittest.main()
