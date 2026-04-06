from __future__ import annotations

import os
import shutil
import tempfile
from pathlib import Path

from fastapi import FastAPI, Form, Request, Response
from fastapi.responses import HTMLResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from git import Repo

from compiler import CompileOptions, compile_repo

app = FastAPI()

BASE_DIR = Path(__file__).resolve().parent
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")

def cleanup_temp_dir(path: str):
    """Safely deletes the temporary directory."""
    try:
        shutil.rmtree(path, ignore_errors=True)
    except Exception as e:
        print(f"Cleanup error: {e}")

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
    # Create a temporary directory for the clone
    temp_dir = tempfile.mkdtemp()

    try:
        # 1. Clone the repository shallowly to save memory/time
        Repo.clone_from(repo_url, temp_dir, multi_options=["--depth", "1"])

        options = CompileOptions(
            preset=preset,
            custom_extensions=custom_extensions,
            include_tree=include_tree,
            include_line_numbers=include_line_numbers,
            max_file_size_kb=max_file_size_kb
        )

        # 2. Compile everything into a string in memory
        result = compile_repo(temp_dir, options)

        # 3. Synchronously delete the temp folder NOW. We are done with it on disk.
        cleanup_temp_dir(temp_dir)

        # 4. Send the string back directly to the user as a downloadable file
        return Response(
            content=result,
            media_type="text/plain",
            headers={"Content-Disposition": 'attachment; filename="compiled.txt"'}
        )

    except Exception as e:
        # If cloning or compiling fails, clean up and return the error safely
        cleanup_temp_dir(temp_dir)
        return PlainTextResponse(str(e), status_code=400)
