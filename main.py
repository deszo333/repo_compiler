from __future__ import annotations

import os
import shutil
import tempfile
from pathlib import Path

from fastapi import FastAPI, Form, Request
from fastapi.responses import FileResponse, HTMLResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from git import Repo

from compiler import CompileOptions, compile_repo

app = FastAPI()

BASE_DIR = Path(__file__).resolve().parent
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")


@app.get("/", response_class=HTMLResponse)
def home(request: Request):
    return templates.TemplateResponse("index.html", {"request": request})


@app.post("/compile")
def compile_endpoint(
    repo_url: str = Form(...),
    preset: str = Form("standard"),
    custom_extensions: str = Form(""),
    include_tree: bool = Form(True),
    include_line_numbers: bool = Form(False),
    max_file_size_kb: int = Form(250)
):
    temp_dir = tempfile.mkdtemp()

    try:
        Repo.clone_from(repo_url, temp_dir, multi_options=["--depth", "1"])

        options = CompileOptions(
            preset=preset,
            custom_extensions=custom_extensions,
            include_tree=include_tree,
            include_line_numbers=include_line_numbers,
            max_file_size_kb=max_file_size_kb
        )

        result = compile_repo(temp_dir, options)

        output_path = os.path.join(temp_dir, "output.txt")
        Path(output_path).write_text(result, encoding="utf-8")

        return FileResponse(output_path, filename="compiled.txt", media_type="text/plain")

    except Exception as e:
        return PlainTextResponse(str(e), status_code=400)
