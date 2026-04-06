from __future__ import annotations

import os
import shutil
import tempfile
from pathlib import Path

from fastapi import FastAPI, Form, Request
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from git import Repo

from compiler import CompileOptions, compile_repo


app = FastAPI(title="Repo to TXT Compiler")

BASE_DIR = Path(__file__).resolve().parent
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")


@app.get("/", response_class=HTMLResponse)
def home(request: Request):
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "default_exclusions": ".git,node_modules,__pycache__,dist,build,.venv,venv,env,.next,coverage",
        },
    )


@app.post("/compile")
def compile_endpoint(
    repo_url: str = Form(...),
    preset: str = Form("standard"),
    custom_extensions: str = Form(""),
    include_tree: bool = Form(True),
    include_hidden: bool = Form(False),
    include_line_numbers: bool = Form(False),
    include_headers: bool = Form(True),
    max_file_size_kb: int = Form(250),
    exclude_dirs: str = Form(".git,node_modules,__pycache__,dist,build,.venv,venv,env,.next,coverage"),
):
    temp_dir = tempfile.mkdtemp(prefix="repo_compiler_")
    output_path = Path(tempfile.mkstemp(prefix="compiled_repo_", suffix=".txt")[1])

    try:
        Repo.clone_from(repo_url, temp_dir, multi_options=["--depth", "1"])

        options = CompileOptions(
            preset=preset,
            custom_extensions=custom_extensions,
            include_tree=include_tree,
            include_hidden=include_hidden,
            include_line_numbers=include_line_numbers,
            include_headers=include_headers,
            max_file_size_kb=max_file_size_kb,
            exclude_dirs=exclude_dirs,
        )

        result = compile_repo(temp_dir, options)

        output_path.write_text(result, encoding="utf-8")

        download_name = f"{Path(temp_dir).name}_compiled.txt"
        return FileResponse(
            path=str(output_path),
            media_type="text/plain",
            filename=download_name,
        )
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)
        # output_path may still be in use by FileResponse; leave cleanup to OS after response
