from __future__ import annotations

import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import Mock, patch


REPO_ROOT = Path(__file__).resolve().parents[1]
BACKEND_ROOT = REPO_ROOT / "Backend"
ADAPTER_PATH = REPO_ROOT / "Frontend" / "src" / "backend" / "adapter.py"

sys.path.insert(0, str(BACKEND_ROOT))

from src.core import daemon  # noqa: E402


def _load_frontend_adapter_module():
    spec = importlib.util.spec_from_file_location("sentry_frontend_adapter_contract", ADAPTER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("Unable to load Frontend adapter module for contract tests.")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


frontend_adapter = _load_frontend_adapter_module()


class TreeQueryContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.project = self.root / "sample_project"
        self.project.mkdir()

        (self.project / "src" / "core").mkdir(parents=True)
        (self.project / "src" / "top.txt").write_text("top", encoding="utf-8")
        (self.project / "src" / "core" / "deep.txt").write_text("deep", encoding="utf-8")
        (self.project / "empty").mkdir()
        (self.project / "ignored" / "nested").mkdir(parents=True)
        (self.project / "ignored" / "nested" / "hidden.txt").write_text("hidden", encoding="utf-8")

        self.target = self.root / "tree.md"
        self.target.write_text(
            "<!-- AUTO_TREE_START -->\n"
            "```\n"
            "sample_project/\n"
            "├── src/    # source annotation\n"
            "└── empty/\n"
            "```\n"
            "<!-- AUTO_TREE_END -->\n",
            encoding="utf-8",
        )

        self.projects_file = self.root / "projects.json"
        self.projects_file.write_text(
            json.dumps(
                [
                    {
                        "uuid": "project-1",
                        "name": "Sample",
                        "path": str(self.project),
                        "target_files": [str(self.target)],
                        "ignore_patterns": ["ignored"],
                    }
                ],
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def _get_project_tree(self, *args: str):
        return daemon.handle_get_project_tree(list(args), projects_file_path=str(self.projects_file))

    def _get_children(self, *args: str):
        return daemon.handle_get_tree_children(list(args), projects_file_path=str(self.projects_file))

    def test_legacy_get_project_tree_remains_unbounded_and_compatible(self) -> None:
        response = self._get_project_tree("project-1")

        self.assertNotIn("max_depth", response)
        self.assertNotIn("depth_limited", response)
        self.assertEqual(response["uuid"], "project-1")
        self.assertEqual(response["tree"]["path_key"], "")
        self.assertTrue(response["tree"]["children_loaded"])

        src = next(child for child in response["tree"]["children"] if child["path_key"] == "src/")
        core = next(child for child in src["children"] if child["path_key"] == "src/core/")
        self.assertTrue(any(child["path_key"] == "src/core/deep.txt" for child in core["children"]))
        self.assertFalse(any(child["path_key"] == "ignored/" for child in response["tree"]["children"]))

    def test_root_depth_zero_and_one_have_distinct_load_metadata(self) -> None:
        depth_zero = self._get_project_tree("project-1", "--max-depth", "0")
        root_zero = depth_zero["tree"]
        self.assertEqual(root_zero["children"], [])
        self.assertTrue(root_zero["has_children"])
        self.assertFalse(root_zero["children_loaded"])
        self.assertTrue(root_zero["depth_limited"])
        self.assertTrue(depth_zero["depth_limited"])

        depth_one = self._get_project_tree("project-1", "--max-depth", "1")
        root_one = depth_one["tree"]
        self.assertTrue(root_one["children_loaded"])
        self.assertEqual({child["path_key"] for child in root_one["children"]}, {"src/", "empty/"})

        src = next(child for child in root_one["children"] if child["path_key"] == "src/")
        empty = next(child for child in root_one["children"] if child["path_key"] == "empty/")
        self.assertTrue(src["has_children"])
        self.assertFalse(src["children_loaded"])
        self.assertTrue(src["depth_limited"])
        self.assertFalse(empty["has_children"])
        self.assertTrue(empty["children_loaded"])
        self.assertFalse(empty["depth_limited"])

    def test_children_query_keeps_project_relative_keys_and_root_annotation_basis(self) -> None:
        response = self._get_children("project-1", "src/", "1")

        self.assertEqual(response["parent_path_key"], "src/")
        self.assertEqual(response["parent"]["path_key"], "src/")
        self.assertEqual(response["parent"]["comment"], "source annotation")
        self.assertEqual(
            {child["path_key"] for child in response["children"]},
            {"src/core/", "src/top.txt"},
        )
        core = next(child for child in response["children"] if child["path_key"] == "src/core/")
        self.assertTrue(core["has_children"])
        self.assertFalse(core["children_loaded"])

    def test_empty_directory_is_distinct_from_unloaded_directory(self) -> None:
        empty = self._get_children("project-1", "empty/", "1")
        self.assertEqual(empty["children"], [])
        self.assertFalse(empty["parent"]["has_children"])
        self.assertTrue(empty["parent"]["children_loaded"])

    def test_path_traversal_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "不得包含 '..'"):
            self._get_children("project-1", "../outside", "1")

    def test_symlink_escape_is_rejected(self) -> None:
        outside = self.root / "outside"
        outside.mkdir()
        link = self.project / "outside_link"
        link.mkdir()

        original_realpath = os.path.realpath

        def fake_realpath(path: str) -> str:
            if Path(path).name == "outside_link":
                return str(outside)
            return original_realpath(path)

        with patch.object(daemon.os.path, "realpath", side_effect=fake_realpath):
            with self.assertRaisesRegex(ValueError, "symlink escape"):
                self._get_children("project-1", "outside_link/", "1")

    def test_adapter_preserves_old_command_and_formats_new_commands(self) -> None:
        adapter = frontend_adapter.BackendAdapter(self.projects_file)
        adapter._run_wsl_command = Mock(return_value={"tree": {}})

        adapter.get_project_tree("project-1")
        adapter._run_wsl_command.assert_called_with("get_project_tree", "project-1")

        adapter.get_project_tree("project-1", max_depth=1)
        adapter._run_wsl_command.assert_called_with(
            "get_project_tree",
            "project-1",
            "--max-depth",
            "1",
        )

        adapter.get_tree_children("project-1", "src/", depth=2)
        adapter._run_wsl_command.assert_called_with(
            "get_tree_children",
            "project-1",
            "src/",
            "2",
        )

    def test_dispatcher_exposes_children_cli_contract(self) -> None:
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            result = daemon.main_dispatcher(
                ["get_tree_children", "project-1", "src/", "1"],
                projects_file_path=str(self.projects_file),
            )

        self.assertEqual(result, 0)
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["parent_path_key"], "src/")
        self.assertEqual({child["path_key"] for child in payload["children"]}, {"src/core/", "src/top.txt"})


if __name__ == "__main__":
    unittest.main()
