# Repo to TXT Compiler

A minimal, professional web app that turns a GitHub repository into one clean `.txt` file for AI workflows, code review, and sharing.

## Features

- Paste a GitHub repo URL
- Download a single `.txt` export
- Include file tree and file headers
- Select presets for different stacks
- Choose custom file extensions
- Set maximum file size
- Include or exclude hidden files
- Phone-friendly UI
- Render-ready deployment

## Local run

```bash
pip install -r requirements.txt
uvicorn main:app --reload
```

Open:

```bash
http://127.0.0.1:8000
```


- Large repositories may take longer to process.
- Binary files are skipped.
- The custom preset accepts extensions like `.py, .js, .php, .ts`.
