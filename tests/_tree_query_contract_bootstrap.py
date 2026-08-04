from __future__ import annotations

import importlib
import importlib.util
import sys
from pathlib import Path
from types import ModuleType


def ensure_backend_import_root(repo_root: Path) -> Path:
    """Expose Backend as the import root used by the existing backend entrypoint."""
    backend_root = repo_root / "Backend"
    backend_root_text = str(backend_root)
    if backend_root_text not in sys.path:
        sys.path.insert(0, backend_root_text)
    return backend_root


def load_backend_daemon(repo_root: Path) -> ModuleType:
    ensure_backend_import_root(repo_root)
    return importlib.import_module("src.core.daemon")


def load_module_from_path(module_name: str, module_path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(module_name, module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load module for contract tests: {module_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module