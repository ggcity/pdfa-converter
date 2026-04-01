# PDF/A Converter

A Ruby Sinatra web application that wraps [OCRmyPDF](https://ocrmypdf.readthedocs.io/) v17+ to perform batch PDF → PDF/A-2b conversion. Upload one or more PDFs (or a ZIP archive of PDFs), convert them to the archival PDF/A-2b format, and download the results.

---

## System Dependencies

Install these before running the application.

### OCRmyPDF (≥ 17.0)

```bash
pip install ocrmypdf>=17.0
# Optional but recommended: pypdfium2 rasterizer (faster, same quality)
pip install pypdfium2
```

### verapdf (for speculative PDF/A conversion)

Download and install from https://verapdf.org/home/#download or via your package manager. Make sure `verapdf` is on your `PATH`.

### Ghostscript

```bash
# Debian/Ubuntu
sudo apt install ghostscript

# macOS (Homebrew)
brew install ghostscript
```

### Tesseract OCR

```bash
# Debian/Ubuntu
sudo apt install tesseract-ocr

# macOS (Homebrew)
brew install tesseract
```

---

## Ruby Dependencies

Requires Ruby ≥ 3.0. Install gems with Bundler:

```bash
gem install bundler
bundle install
```

---

## Running the Application

### Development

```bash
bundle exec ruby app.rb
```

The app will start on `http://0.0.0.0:4567` by default.

### Production (Puma)

```bash
bundle exec puma config.ru -p 4567 -t 4:8
```

Or use a `Procfile` / systemd unit pointing at `puma config.ru`.

### Environment Variables

| Variable        | Default | Description                         |
|-----------------|---------|-------------------------------------|
| `MAX_UPLOAD_MB` | `100`   | Maximum total upload size in MB     |

---

## Cron Job (Required for Cleanup)

The application performs a **boot-time cleanup** of job directories older than 6 hours. For routine cleanup during normal operation, add the following cron entry (adjust the path):

```cron
*/10 * * * * find /path/to/app/tmp/jobs -mindepth 1 -maxdepth 1 -type d -mmin +60 -exec rm -rf {} +
```

This removes job directories older than 60 minutes, running every 10 minutes. Files are available for download for up to 1 hour after job creation.

---

## Application Routes

| Method | Path                  | Description                             |
|--------|-----------------------|-----------------------------------------|
| `GET`  | `/`                   | Upload page (main UI)                   |
| `POST` | `/upload`             | Accepts file(s), starts conversion job  |
| `GET`  | `/status/:job_id`     | JSON status of a conversion job         |
| `GET`  | `/download/:job_id`   | Download converted file(s)              |

---

## OCRmyPDF Flags Used

```
ocrmypdf \
  --output-type auto \
  --rasterizer auto \
  --skip-text \
  --optimize 1 \
  --pdfa-image-compression lossless \
  --jobs 1 \
  input.pdf output.pdf
```

- `--output-type auto` — speculative pikepdf+verapdf PDF/A conversion; Ghostscript fallback only when needed
- `--rasterizer auto` — uses pypdfium2 when available
- `--skip-text` — preserves existing text layers; skips pages that already have extractable text
- `--optimize 1` — lossless optimizations only
- `--pdfa-image-compression lossless` — prevents lossy transcoding during Ghostscript step
- `--jobs 1` — per-file parallelism (multiple files are processed sequentially per job)

---

## Security Notes

- Job IDs are `SecureRandom.uuid` (122 bits of entropy) and serve as the sole access credential for downloads.
- Job IDs are never logged in full, never returned in error pages, and never enumerated via any endpoint.
- All filenames are sanitised server-side (path-traversal characters stripped).
- PDF magic bytes (`%PDF-`) are validated for every file regardless of extension.
- Converted files are served exclusively through `/download/:job_id` — not as static files.
- The `tmp/jobs/` directory is not web-accessible.
- Run the application as a non-root user.

---

## Project Structure

```
.
├── app.rb              # Main Sinatra application
├── config.ru           # Rackup / Puma entry point
├── Gemfile
├── Gemfile.lock
├── public/
│   └── style.css       # Minimal custom styles
├── views/
│   └── index.erb       # Upload / progress / download UI
├── tmp/
│   └── jobs/           # Job working directories (auto-cleaned)
└── README.md
```
