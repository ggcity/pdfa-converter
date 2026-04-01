# Agentic AI Prompt: OCRmyPDF Sinatra Web Tool

## Project Overview

Build a Ruby Sinatra web application that wraps OCRmyPDF v17+ for batch PDF-to-PDF/A conversion. The app allows users to upload one or more PDFs (or a ZIP archive of PDFs), converts them to PDF/A-2b using OCRmyPDF's latest pipeline (pypdfium2 rasterizer, speculative pikepdf+verapdf PDF/A conversion, Ghostscript fallback), and returns the converted files as a download — single PDF if one file, ZIP archive if multiple.

## Tech Stack

- **Backend:** Ruby + Sinatra (classic style, single-file app is fine unless complexity warrants modular)
- **Frontend:** Bootstrap 5 (CDN), vanilla JavaScript (no frameworks)
- **Processing:** OCRmyPDF v17+ with pypdfium2, verapdf, Ghostscript, Tesseract
- **File handling:** Ruby stdlib + `rubyzip` gem for ZIP creation/extraction
- **Server:** Puma (for concurrent request handling during long conversions)

## System Dependencies (document in README)

```
ocrmypdf >= 17.0
pypdfium2 (pip install pypdfium2)
verapdf
ghostscript
tesseract-ocr
```

## Application Architecture

### Routes

```
GET  /                  → Upload page (main UI)
POST /upload            → Receives files, validates, queues processing, returns job_id
GET  /status/:job_id    → Returns JSON status of a conversion job (for progress polling)
GET  /download/:job_id  → Serves the converted file(s) if output dir exists, 404 otherwise
```

The job_id (SecureRandom.uuid) is the sole access credential. See "Security: Download Authorization" below for details.

### Job Processing Flow

1. User uploads file(s) via multipart form (accept `.pdf` files and `.zip` files)
2. Server generates a unique job ID (SecureRandom.uuid)
3. Server creates a working directory: `tmp/jobs/{job_id}/input/` and `tmp/jobs/{job_id}/output/`
4. If ZIP uploaded: extract to input directory, flatten any nested directory structure
5. Validate every file in input directory:
   - Check file extension is `.pdf` (case-insensitive)
   - Validate PDF magic bytes (first 5 bytes should be `%PDF-`)
   - Reject non-PDF files, record rejections in job status
6. Spawn a background thread (or use a simple Thread-based worker) to process files
7. For each valid PDF, run OCRmyPDF conversion (details below)
8. Track progress: number of files completed / total files
9. When done: if single output file, leave as PDF; if multiple, create ZIP archive in output directory
10. Mark job as complete

### OCRmyPDF Command

Use the latest v17 features for maximum fidelity:

```bash
ocrmypdf \
  --output-type auto \
  --rasterizer auto \
  --skip-text \
  --optimize 1 \
  --pdfa-image-compression lossless \
  --jobs 1 \
  "input.pdf" "output.pdf"
```

Key flags and rationale:
- `--output-type auto` — uses speculative pikepdf+verapdf PDF/A conversion, falls back to Ghostscript only when needed. This is the most content-preserving path available.
- `--rasterizer auto` — prefers pypdfium2 when available (faster, equivalent quality)
- `--skip-text` — do not re-OCR pages that already have extractable text (preserves existing text layers)
- `--optimize 1` — safe lossless optimizations only
- `--pdfa-image-compression lossless` — prevent lossy image transcoding during Ghostscript PDF/A step
- `--jobs 1` — per-file parallelism set to 1 since we may process multiple files concurrently at the app level

Capture both stdout and stderr from the command. Store exit code per file. OCRmyPDF exit codes to handle:
- 0 = success
- 6 = already has OCR (still succeeds with --skip-text)
- Non-zero = failure, log stderr, mark file as failed in job status



### Security: Download Authorization

The job_id itself (SecureRandom.uuid, 122 bits of entropy) serves as the access token. There is no separate auth token — knowing the job_id IS the credential. This is sufficient because:
- Job IDs are unguessable (SecureRandom.uuid)
- Job IDs are only ever returned to the browser that initiated the upload
- No endpoint enumerates or exposes job IDs

**Critical rule:** Never leak job IDs in logs, error pages, admin views, or any other output. If you log job activity, redact or truncate the ID.

### Download

**Flow:**
1. `GET /download/:job_id` — check if `tmp/jobs/{job_id}/output/` exists and contains a file
2. If the directory doesn't exist (cron deleted it, or app boot cleaned it up), return **404** with a message: "This file is no longer available."
3. If it exists and contains output, serve the file via `send_file`
4. The file remains downloadable until cron or app restart cleans it up — no download tracking, no flags, no state

**Simplicity rationale:** Cleanup is handled entirely by cron (60-minute expiry) and app boot (6-hour safety net). There is no download-count tracking. The file is available for repeated downloads until it's cleaned up. The job_id's unguessability is the access control.

### Job Status JSON Schema

The status endpoint returns an `expires_at` ISO8601 timestamp so the frontend can display a countdown:

```json
{
  "job_id": "uuid",
  "status": "processing|complete|failed",
  "total_files": 5,
  "completed_files": 3,
  "failed_files": 0,
  "current_file": "document3.pdf",
  "created_at": "2026-03-31T14:30:00Z",
  "expires_at": "2026-03-31T15:30:00Z",
  "files": [
    {
      "name": "document1.pdf",
      "status": "done|processing|failed|rejected",
      "error": null
    }
  ],
  "download_ready": false,
  "download_filename": null
}
```

### Cleanup Strategy

**Two layers of cleanup:**

1. **Application boot:** On startup, scan `tmp/jobs/` and delete any job directory with an mtime older than 6 hours. This catches anything left behind by crashes, restarts, or missed cron runs.

2. **Cron job (primary cleanup):** A system cron entry handles routine cleanup independent of the app process. Add to crontab:
   ```
   */10 * * * * find /path/to/app/tmp/jobs -mindepth 1 -maxdepth 1 -type d -mmin +60 -exec rm -rf {} +
   ```
   This deletes job directories older than 60 minutes, runs every 10 minutes. The app does not need to manage cleanup — cron does.

## Frontend UI

### Design Principles
- Minimal, clean, not ugly. Bootstrap 5 default theme is fine.
- Single page — no navigation, no unnecessary chrome
- City/municipal tool aesthetic: professional, not flashy

### Layout

```
┌─────────────────────────────────────────────────┐
│  PDF/A Converter                                │
│  Convert PDFs to archival PDF/A-2b format       │
├─────────────────────────────────────────────────┤
│                                                 │
│  ┌───────────────────────────────────────────┐  │
│  │                                           │  │
│  │   Drag & drop PDF files or a ZIP here     │  │
│  │   — or click to browse —                  │  │
│  │                                           │  │
│  │   Accepts: .pdf, .zip                     │  │
│  └───────────────────────────────────────────┘  │
│                                                 │
│  ┌───────────────────────────────────────────┐  │
│  │ Selected files:                           │  │
│  │  ☑ report2024.pdf          1.2 MB         │  │
│  │  ☑ agenda-march.pdf        340 KB         │  │
│  │  ☑ contracts.zip           8.4 MB         │  │
│  └───────────────────────────────────────────┘  │
│                                                 │
│  [ Convert to PDF/A ]                           │  ← btn-primary
│                                                 │
│  ── Progress ──────────────────────────────────  │
│  ████████████░░░░░░░░░░░░░░░░  3 / 5 files     │
│  Processing: document3.pdf                      │
│                                                 │
│  ✓ document1.pdf — converted                    │
│  ✓ document2.pdf — converted                    │
│  ⟳ document3.pdf — processing...                │
│  · document4.pdf — queued                       │
│  · document5.pdf — queued                       │
│                                                 │
│  ── Complete ──────────────────────────────────  │
│  [ Download Converted Files ]   ← btn-success   │
│                                                  │
│  ⏱ File available for: 47:23                    │
│                                                  │
└─────────────────────────────────────────────────┘
```

### Expiry Countdown Timer

When conversion is complete and the download button appears, show a countdown timer next to or below the button:

- The status JSON includes `expires_at` (ISO8601 timestamp, 1 hour after job creation)
- JavaScript calculates the remaining time client-side: `new Date(expires_at) - new Date()`
- Display as `MM:SS` format, updating every second via `setInterval`
- Use muted/secondary text styling (Bootstrap `text-muted`)
- When the timer reaches zero:
  - Replace the download button with a disabled state or a message: "This file has expired."
  - Stop the countdown interval
  - Optionally add a Bootstrap `alert-warning` explaining the file is no longer available

### Progress Bar Behavior

This is a semi-pseudo progress bar — it cannot track real progress within a single file's OCRmyPDF conversion, but it CAN track file-by-file progress in a batch:

- Poll `GET /status/:job_id` every 2 seconds via JavaScript fetch()
- Progress bar width = (completed_files / total_files) * 100
- Within a single file's processing, use a subtle indeterminate animation (Bootstrap striped animated progress bar) for the current file's segment
- File list below the bar updates with status icons as each completes
- When job is complete, show download button, stop polling

### Drag and Drop

- Implement a drag-and-drop zone using vanilla JS
- Highlight zone on dragover (Bootstrap border-primary)
- Also support click-to-browse via hidden file input
- Accept multiple files via `multiple` attribute
- Client-side validation: check file extensions before upload, show warning for non-PDF/non-ZIP files

### Error Handling UI

- If some files fail conversion, show them in red with the error message
- Still allow download of successfully converted files
- If ALL files fail, show an error summary, no download button

## File Size and Security Considerations

- Set a max upload size (configurable, default 100MB total per request)
- Set Sinatra's max request body size accordingly
- Sanitize all filenames — strip path traversal characters, normalize to ASCII-safe names
- Do not trust file extensions alone — validate PDF magic bytes server-side
- Run OCRmyPDF as the app user, not root
- The tmp/jobs directory should not be web-accessible
- **Converted files are never served statically.** They are served exclusively through the `GET /download/:job_id` route, which checks authorization (valid job_id), expiry (1 hour), and download status (one-time only)
- Never expose job IDs in logs, error responses, or any endpoint other than the POST /upload response to the uploading client

## Gemfile

```ruby
source "https://rubygems.org"

gem "sinatra"
gem "puma"
gem "rubyzip"
```

## Project File Structure

```
pdfa-converter/
├── app.rb              # Main Sinatra application
├── config.ru           # Rackup file
├── Gemfile
├── Gemfile.lock
├── public/
│   └── style.css       # Minimal custom styles (if any beyond Bootstrap)
├── views/
│   └── index.erb       # Main upload page
├── tmp/
│   └── jobs/           # Working directory for conversion jobs
└── README.md           # Setup instructions, system dependencies
```

## Implementation Notes

- Keep it simple. This is a utility tool, not a SaaS product.
- Sinatra classic style is fine. Don't over-engineer.
- Use Ruby's Thread for background processing. No need for Sidekiq/Redis for this use case. Store job status in a simple in-memory Hash protected by a Mutex.
- Be aware that the in-memory job store means job status is lost on server restart. That's acceptable for this tool.
- **Boot cleanup:** When the Sinatra app starts (in `configure` block or top-level), scan `tmp/jobs/` and delete any directory with an mtime older than 6 hours. This is a safety net for stale files surviving crashes or missed cron runs. Log what gets deleted.
- **Cron setup:** Document in README that the following cron entry is required:
  ```
  */10 * * * * find /path/to/app/tmp/jobs -mindepth 1 -maxdepth 1 -type d -mmin +60 -exec rm -rf {} +
  ```
- If a ZIP contains nested directories, flatten the structure — only process `.pdf` files found at any depth.
- Preserve original filenames in the output (converted files keep their original names).
- The output ZIP should mirror the input filenames, not use UUIDs.
- Log OCRmyPDF stderr to a log file per job for debugging.
- Test with: single PDF upload, multiple PDF upload, ZIP upload, ZIP containing non-PDFs mixed with PDFs, corrupt/non-PDF file with .pdf extension, empty upload, very large file.