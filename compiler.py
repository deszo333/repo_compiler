from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


STANDARD_EXTENSIONS = {
    ".py", ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs",
    ".php", ".html", ".htm", ".css", ".scss", ".sass", ".less",
    ".java", ".kt", ".kts", ".cs", ".go", ".rs", ".rb",
    ".c", ".h", ".cpp", ".hpp", ".cc", ".hh", ".swift",
    ".sh", ".bash", ".zsh", ".ps1", ".sql", ".json", ".yaml",
    ".yml", ".toml", ".xml", ".md", ".txt", ".ini", ".cfg",
    ".env", ".dockerfile", ".gradle", ".properties",
}

PRESET_EXTENSIONS = {
    "standard": STANDARD_EXTENSIONS,
    "code_only": {
        ".py", ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs",
        ".php", ".java", ".kt", ".kts", ".cs", ".go", ".rs",
        ".rb", ".c", ".h", ".cpp", ".hpp", ".cc", ".hh",
        ".swift", ".sh", ".bash", ".zsh", ".ps1", ".sql",
        ".json", ".yaml", ".yml", ".toml", ".xml",
    },
    "frontend": {
        ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs",
        ".html", ".htm", ".css", ".scss", ".sass", ".less",
        ".json", ".md", ".yaml", ".yml",
    },
    "backend": {
        ".py", ".php", ".js", ".ts", ".mjs", ".cjs",
        ".java", ".kt", ".kts", ".cs", ".go", ".rs",
        ".rb", ".sql", ".yaml", ".yml", ".toml", ".sh",
    },
    "javascript": {
        ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs",
        ".json", ".html", ".htm", ".css", ".scss", ".sass",
    },
    "php": {
        ".php", ".phtml", ".inc", ".html", ".htm", ".css", ".js", ".json",
    },
    "python": {
        ".py", ".pyw", ".ipynb", ".txt", ".md", ".toml", ".yaml", ".yml",
    },
    "all_files": None,
}


EXCLUDED_DIRS_DEFAULT = {
    ".git", ".svn", ".hg", ".idea", ".vscode", "__pycache__", "node_modules",
    "dist", "build", ".next", ".nuxt", ".venv", "venv", "env", ".pytest_cache",
    "coverage", ".mypy_cache", ".tox", ".cache", "vendor",
}

BINARY_EXTENSIONS = {
    ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico", ".webp", ".pdf",
    ".zip", ".rar", ".7z", ".gz", ".tar", ".exe", ".dll", ".so", ".dylib",
    ".ttf", ".otf", ".woff", ".woff2", ".mp3", ".mp4", ".mov", ".avi",
}


@dataclass
class CompileOptions:
    preset: str = "standard"
    custom_extensions: str = ""
    include_tree: bool = True
    include_hidden: bool = False
    include_line_numbers: bool = False
    include_headers: bool = True
    max_file_size_kb: int = 250
    exclude_dirs: str = ""


def parse_extensions(text: str) -> set[str]:
    items = re.split(r"[,\s]+", text.strip().lower())
    result: set[str] = set()
    for item in items:
        if not item:
            continue
        if not item.startswith("."):
            item = "." + item
        result.add(item)
    return result


def normalize_dir_names(text: str) -> set[str]:
    items = re.split(r"[,\s]+", text.strip())
    return {item for item in items if item}


def get_allowed_extensions(options: CompileOptions) -> set[str] | None:
    preset = (options.preset or "standard").strip().lower()
    if preset == "custom":
        return parse_extensions(options.custom_extensions)
    if preset in PRESET_EXTENSIONS:
        return PRESET_EXTENSIONS[preset]
    return STANDARD_EXTENSIONS


def is_hidden_path(path: Path) -> bool:
    return any(part.startswith(".") for part in path.parts if part not in (".", ".."))


def should_skip_dir(path: Path, excluded_dirs: set[str], include_hidden: bool) -> bool:
    parts = set(path.parts)
    if not include_hidden and is_hidden_path(path):
        return True
    return bool(parts & excluded_dirs)


def should_skip_file(path: Path, allowed_extensions: set[str] | None, max_bytes: int, include_hidden: bool) -> bool:
    if not include_hidden and is_hidden_path(path):
        return True

    if path.name in {"package-lock.json"}:
        # still safe to include because text, but keep standard filtering behavior
        pass

    if path.suffix.lower() in BINARY_EXTENSIONS:
        return True

    try:
        size = path.stat().st_size
    except OSError:
        return True

    if size > max_bytes:
        return True

    if allowed_extensions is None:
        return False

    if allowed_extensions and path.suffix.lower() in allowed_extensions:
        return False

    # special-case Dockerfile and files without suffix
    if path.name.lower() == "dockerfile" and ".dockerfile" in allowed_extensions:
        return False
    if not path.suffix and "makefile" in {x.lower() for x in allowed_extensions} and path.name.lower() == "makefile":
        return False

    return True


def safe_read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        try:
            return path.read_text(encoding="utf-8-sig")
        except Exception:
            return None
    except Exception:
        return None


def build_tree(root: Path, excluded_dirs: set[str], include_hidden: bool) -> str:
    lines: list[str] = []
    root = root.resolve()

    def walk(current: Path, prefix: str = ""):
        entries: list[Path] = []
        try:
            entries = sorted(current.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower()))
        except Exception:
            return

        visible = []
        for entry in entries:
            if not include_hidden and entry.name.startswith("."):
                continue
            if entry.is_dir() and entry.name in excluded_dirs:
                continue
            if entry.is_dir() and should_skip_dir(entry, excluded_dirs, include_hidden):
                continue
            visible.append(entry)

        for index, entry in enumerate(visible):
            connector = "└── " if index == len(visible) - 1 else "├── "
            lines.append(f"{prefix}{connector}{entry.name}")
            if entry.is_dir():
                extension = "    " if index == len(visible) - 1 else "│   "
                walk(entry, prefix + extension)

    lines.append(root.name + "/")
    walk(root)
    return "
".join(lines)


def iter_files(root: Path, excluded_dirs: set[str], include_hidden: bool) -> Iterable[Path]:
    for dirpath, dirnames, filenames in os.walk(root):
        current_dir = Path(dirpath)

        # prune directories in place
        kept = []
        for d in sorted(dirnames):
            p = current_dir / d
            if should_skip_dir(p, excluded_dirs, include_hidden):
                continue
            kept.append(d)
        dirnames[:] = kept

        for filename in sorted(filenames):
            p = current_dir / filename
            if not include_hidden and p.name.startswith("."):
                continue
            yield p


def apply_line_numbers(text: str) -> str:
    numbered = []
    for idx, line in enumerate(text.splitlines(), start=1):
        numbered.append(f"{idx:4d}: {line}")
    if text.endswith("
"):
        numbered.append("")
    return "
".join(numbered)


def compile_repo(root_dir: str | Path, options: CompileOptions) -> str:
    root = Path(root_dir)
    excluded_dirs = EXCLUDED_DIRS_DEFAULT | normalize_dir_names(options.exclude_dirs)
    allowed_extensions = get_allowed_extensions(options)
    max_bytes = max(1, int(options.max_file_size_kb)) * 1024

    repo_name = root.name
    output: list[str] = []
    output.append(f"REPOSITORY: {repo_name}")
    output.append(f"ROOT: {root.as_posix()}")
    output.append(f"PRESET: {options.preset}")
    if options.preset == "custom":
        output.append(f"CUSTOM EXTENSIONS: {options.custom_extensions.strip() or '(none)'}")
    output.append(f"INCLUDE TREE: {'yes' if options.include_tree else 'no'}")
    output.append(f"INCLUDE HEADERS: {'yes' if options.include_headers else 'no'}")
    output.append(f"INCLUDE LINE NUMBERS: {'yes' if options.include_line_numbers else 'no'}")
    output.append(f"INCLUDE HIDDEN: {'yes' if options.include_hidden else 'no'}")
    output.append(f"MAX FILE SIZE: {options.max_file_size_kb} KB")
    output.append("")

    if options.include_tree:
        output.append("FILE TREE")
        output.append("---------")
        output.append(build_tree(root, excluded_dirs, options.include_hidden))
        output.append("")

    output.append("FILES")
    output.append("-----")

    included_count = 0
    skipped_count = 0

    for path in iter_files(root, excluded_dirs, options.include_hidden):
        if not path.is_file():
            continue

        if should_skip_file(path, allowed_extensions, max_bytes, options.include_hidden):
            skipped_count += 1
            continue

        text = safe_read_text(path)
        if text is None:
            skipped_count += 1
            continue

        included_count += 1
        relative = path.relative_to(root).as_posix()

        if options.include_headers:
            output.append("")
            output.append(f"File: {relative}")
            output.append("-" * (6 + len(relative)))

        if options.include_line_numbers:
            text = apply_line_numbers(text)

        output.append(text.rstrip("
"))

    output.append("")
    output.append("SUMMARY")
    output.append("-------")
    output.append(f"Included files: {included_count}")
    output.append(f"Skipped files: {skipped_count}")

    return "
".join(output) + "
"
