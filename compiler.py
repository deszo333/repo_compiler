from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path

PRESETS = {
    "standard": None,
    "code_only": {".py", ".js", ".ts", ".php"},
    "frontend": {".js", ".html", ".css"},
    "backend": {".py", ".php"},
    "javascript": {".js"},
    "php": {".php"},
    "python": {".py"},
    "all_files": None,
}

EXCLUDE_DIRS = {".git", "node_modules", "__pycache__", "venv", ".venv"}


@dataclass
class CompileOptions:
    preset: str = "standard"
    custom_extensions: str = ""
    include_tree: bool = True
    include_line_numbers: bool = False
    max_file_size_kb: int = 250


def parse_ext(text: str):
    return {("." + x.strip().lower().lstrip(".")) for x in re.split(r"[,\s]+", text) if x}


def allowed_ext(options: CompileOptions):
    if options.preset == "custom":
        return parse_ext(options.custom_extensions)
    return PRESETS.get(options.preset, None)


def build_tree(root: Path):
    lines = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in EXCLUDE_DIRS]
        level = dirpath.replace(str(root), "").count(os.sep)
        indent = "  " * level
        lines.append(f"{indent}{os.path.basename(dirpath)}/")
        for f in filenames:
            lines.append(f"{indent}  {f}")
    return "\n".join(lines)


def compile_repo(root_dir, options: CompileOptions):
    root = Path(root_dir)
    allowed = allowed_ext(options)
    max_bytes = options.max_file_size_kb * 1024

    output = [f"REPO: {root.name}\n"]

    if options.include_tree:
        output.append("FILE TREE:\n")
        output.append(build_tree(root))
        output.append("\n")

    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in EXCLUDE_DIRS]

        for file in filenames:
            path = Path(dirpath) / file

            if ".git" in path.parts:
                continue

            if allowed and path.suffix.lower() not in allowed:
                continue

            try:
                if path.stat().st_size > max_bytes:
                    continue
            except:
                continue

            try:
                content = path.read_text(encoding="utf-8")
            except:
                continue

            rel = path.relative_to(root)
            output.append(f"\n--- FILE: {rel} ---\n")

            if options.include_line_numbers:
                content = "\n".join(
                    f"{i+1:4d}: {line}" for i, line in enumerate(content.splitlines())
                )

            output.append(content)

    return "\n".join(output)
