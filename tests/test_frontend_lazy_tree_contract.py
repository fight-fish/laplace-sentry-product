import importlib.util
import json
import os
import sys
import tempfile
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



class ConnectableSignal:
    def __init__(self):
        self.callbacks = []

    def connect(self, callback):
        self.callbacks.append(callback)
        return None

    def emit(self, *args, **kwargs):
        for callback in list(self.callbacks):
            callback(*args, **kwargs)


class CaptureSignal:
    def __init__(self):
        self.emitted = []

    def emit(self, *args):
        self.emitted.append(args)


class FakeThread:
    def __init__(self, *args, **kwargs):
        self.started = ConnectableSignal()
        self.finished = ConnectableSignal()

    def start(self):
        return None

    def quit(self):
        self.finished.emit()

    def deleteLater(self):
        return None


class TemporaryInstrumentationEnvironment:
    """用受控 TEMP 驗證 trace；離開時還原 tempfile 快取與環境變數。"""

    def __init__(self, enabled):
        self.enabled = enabled
        self.tmp = tempfile.TemporaryDirectory()
        self.original_tempdir = tempfile.tempdir
        self.patcher = None

    def __enter__(self):
        env = {
            "TEMP": self.tmp.name,
            "TMP": self.tmp.name,
        }
        if self.enabled:
            env["LAPLACE_SENTRY_INSTRUMENTATION"] = "1"
        else:
            env["LAPLACE_SENTRY_INSTRUMENTATION"] = ""
        self.patcher = patch.dict(os.environ, env, clear=False)
        self.patcher.__enter__()
        tempfile.tempdir = None
        return Path(self.tmp.name)

    def __exit__(self, exc_type, exc, tb):
        tempfile.tempdir = self.original_tempdir
        if self.patcher is not None:
            self.patcher.__exit__(exc_type, exc, tb)
        self.tmp.cleanup()
        return False

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
            elif isinstance(original, types.ModuleType):
                sys.modules[name] = original
            else:
                raise AssertionError(f"unexpected saved module type for {name}")
        sys.path[:] = self.original_sys_path

    def _install_fake_pyside_modules(self):
        pyside = types.ModuleType("PySide6")
        qtcore = types.ModuleType("PySide6.QtCore")
        qtgui = types.ModuleType("PySide6.QtGui")
        qtwidgets = types.ModuleType("PySide6.QtWidgets")

        setattr(qtcore, "Qt", FakeQt)
        setattr(qtcore, "Signal", Signal)
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
        setattr(qtwidgets, "QTreeWidgetItem", FakeItem)

        sys.modules["PySide6"] = pyside
        sys.modules["PySide6.QtCore"] = qtcore
        sys.modules["PySide6.QtGui"] = qtgui
        sys.modules["PySide6.QtWidgets"] = qtwidgets

    def _load_tray_app_module(self):
        frontend_path = str(FRONTEND_ROOT)
        if frontend_path not in sys.path:
            sys.path.insert(0, frontend_path)

        spec = importlib.util.spec_from_file_location(TRAY_APP_TEST_MODULE, TRAY_APP_PATH)
        if spec is None or spec.loader is None:
            raise RuntimeError(f"cannot load tray app module from {TRAY_APP_PATH}")
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        setattr(module, "QTreeWidgetItem", FakeItem)
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



    def read_trace_records(self, tray_app):
        trace_path = tray_app._s0206_trace_path()
        self.assertTrue(trace_path.exists(), f"expected trace file at {trace_path}")
        lines = trace_path.read_text(encoding="utf-8").splitlines()
        self.assertGreaterEqual(len(lines), 1)
        return [json.loads(line) for line in lines]

    def test_instrumentation_off_does_not_create_trace_file_or_directory(self):
        with TemporaryInstrumentationEnvironment(enabled=False) as tmp_root:
            tray_app = self.load_tray_app_for_test()
            dashboard = self.make_dashboard(tray_app)
            item = FakeItem(["src/"])
            item.setData(
                0,
                FakeQt.ItemDataRole.UserRole,
                {
                    "is_dir": True,
                    "has_children": True,
                    "children_loaded": True,
                    "children_loading": False,
                    "project_uuid": "project-1",
                    "path_key": "src/",
                },
            )

            dashboard._on_tree_item_expanded(item)
            dashboard._on_tree_item_collapsed(item)

            self.assertFalse((tmp_root / "LaplaceSentry").exists())

    def test_instrumentation_on_records_expand_collapse_without_sensitive_values(self):
        fake_uuid = "project-secret-uuid-1234567890"
        sensitive_path = "C:/Users/User/secret-project/top.txt"
        with TemporaryInstrumentationEnvironment(enabled=True):
            tray_app = self.load_tray_app_for_test()
            dashboard = self.make_dashboard(tray_app)
            item = FakeItem(["secret"])
            item.setData(
                0,
                FakeQt.ItemDataRole.UserRole,
                {
                    "is_dir": True,
                    "has_children": True,
                    "children_loaded": True,
                    "children_loading": False,
                    "project_uuid": fake_uuid,
                    "path_key": sensitive_path,
                },
            )

            dashboard._on_tree_item_expanded(item)
            dashboard._on_tree_item_collapsed(item)
            dashboard._s0206_record_event(
                "query_fail",
                query_kind="tree_children:src/",
                path_key="src/",
                request_id=5,
                outcome="exception",
                command="wsl --secret-arg TOPSECRET",
                stdout="stdout TOPSECRET",
                stderr="stderr TOPSECRET",
                env="TOKEN=TOPSECRET",
            )

            trace_bytes = tray_app._s0206_trace_path().read_bytes()
            self.assertNotIn(fake_uuid.encode("utf-8"), trace_bytes)
            self.assertNotIn(b"C:/Users/User", trace_bytes)
            self.assertNotIn(b"TOPSECRET", trace_bytes)
            records = self.read_trace_records(tray_app)

        events = [record["event"] for record in records]
        self.assertIn("tree_expand", events)
        self.assertIn("tree_expand_decision", events)
        self.assertIn("tree_collapse", events)
        decision = next(record for record in records if record["event"] == "tree_expand_decision")
        self.assertEqual(decision["decision"], "already_loaded")
        self.assertEqual(decision["path_key"], "[redacted]")

    def test_instrumentation_records_query_timing_identity_and_rejected_decision(self):
        with TemporaryInstrumentationEnvironment(enabled=True):
            tray_app = self.load_tray_app_for_test()
            dashboard = self.make_dashboard(tray_app)
            dashboard._current_selected_project_uuid = lambda: "project-1"
            dashboard._latest_children_request_ids = {("project-1", "src/"): 99}
            setattr(tray_app, "QThread", FakeThread)

            dashboard._start_project_query(
                "tree_children:src/",
                "project-1",
                lambda uuid: {"uuid": uuid},
            )
            dashboard._on_project_query_finished(
                "tree_children:src/",
                "project-1",
                7,
                {"uuid": "project-1"},
                12.5,
            )
            records = self.read_trace_records(tray_app)

        events = [record["event"] for record in records]
        self.assertIn("query_start", events)
        self.assertIn("query_finish", events)
        self.assertIn("query_result_decision", events)
        finish = next(record for record in records if record["event"] == "query_finish")
        self.assertEqual(finish["request_id"], 7)
        self.assertEqual(finish["query_kind"], "tree_children:src/")
        self.assertGreaterEqual(finish["query_elapsed_ms"], 0.0)
        decision = next(record for record in records if record["event"] == "query_result_decision")
        self.assertEqual(decision["decision"], "guard_rejected")
        self.assertEqual(decision["reason"], "stale_children_request")

    def test_project_query_worker_emits_callable_elapsed_without_changing_result(self):
        tray_app = self.load_tray_app_for_test()
        worker = tray_app.ProjectQueryWorker(
            "tree_children:src/",
            "project-1",
            3,
            lambda uuid: {"uuid": uuid, "children": []},
        )
        worker.finished = CaptureSignal()
        worker.failed = CaptureSignal()

        worker.run()

        self.assertEqual(worker.failed.emitted, [])
        self.assertEqual(len(worker.finished.emitted), 1)
        query_kind, project_uuid, request_id, result, elapsed_ms = worker.finished.emitted[0]
        self.assertEqual(query_kind, "tree_children:src/")
        self.assertEqual(project_uuid, "project-1")
        self.assertEqual(request_id, 3)
        self.assertEqual(result, {"uuid": "project-1", "children": []})
        self.assertGreaterEqual(elapsed_ms, 0.0)

if __name__ == "__main__":
    unittest.main()
