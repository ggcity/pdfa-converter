# PDF LeGGacy (PDF/A Converter)

A Ruby Sinatra web application that wraps [OCRmyPDF](https://ocrmypdf.readthedocs.io/) v17+ to perform batch PDF → PDF/A-2b conversion. Upload one or more PDFs (or a ZIP archive of PDFs), convert them to the archival PDF/A-2b format, and download the results.

Part of the GG IT Toolbox family (launcher at https://toolbox.ggcity.org, `/leggacy`). Production runs at https://ch.ggcity.org/pdfa-converter. Unlike the other toolbox tools, which work entirely in the browser, this one **uploads files to the server**. They are deleted when the download window ("the vault") closes.

Files that are **already PDF/A-2b conformant** are detected before conversion and passed through unchanged — skipping OCRmyPDF entirely for those files.

---

## System Dependencies

Install these before running the application.

### OCRmyPDF (≥ 17.0)

```bash
pip install ocrmypdf>=17.0
# Optional but recommended: pypdfium2 rasterizer (faster, same quality)
pip install pypdfium2
```

### verapdf (optional, via Podman)

Used for two purposes:

1. **Pre-conversion check** — before running OCRmyPDF, verapdf inspects the input file. If it is already PDF/A-2b conformant the file is passed through unchanged and OCRmyPDF is skipped.
2. **Post-conversion validation** — after a successful conversion, verapdf verifies that the output meets PDF/A-2b requirements. The result is included in the job status response.

verapdf runs via the `verapdf/cli` Podman image — no local installation required. If Podman is not available (or the image is not pulled), both checks are silently skipped and conversion proceeds normally.

```bash
podman pull verapdf/cli
```

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

### Production (Passenger)

Production is served by Phusion Passenger from `/var/www/rails/pdfa-converter`, mounted at the `/pdfa-converter` sub-path. Passenger picks up `config.ru` and sets `RACK_ENV=production` by default. In production the app runs OCRmyPDF from `/var/www/rails/pdfa-converter/.venv/bin/ocrmypdf`.

Conversions run in a background `Thread` inside the Passenger worker process that accepted the upload. If Passenger shuts that process down (idle timeout, or a restart via `touch tmp/restart.txt` / deploy), any conversion in flight is killed and the job stays at "processing" forever. To reduce this:

```nginx
passenger_min_instances 1;
passenger_pool_idle_time 3600;   # longer than the biggest expected batch
```

Avoid restarting the app while jobs are running.

For a local production-like run you can still use Puma:

```bash
RACK_ENV=production bundle exec puma config.ru -p 4567 -t 4:8
```

### Logging

- **Production** (`RACK_ENV=production`): request lines and job events are appended to `logs/app.log`.
- **Everywhere else:** they go to stdout.

Job IDs are logged as their first 8 characters only. The app doesn't rotate the log itself, because Ruby's `Logger` rotation isn't safe with several Passenger processes. Use logrotate with `copytruncate`:

```
/var/www/rails/pdfa-converter/logs/app.log {
  weekly
  rotate 8
  compress
  missingok
  notifempty
  copytruncate
}
```

Per-file OCRmyPDF/verapdf output is still written to `tmp/jobs/<id>/logs/` and removed along with the job.

### Environment Variables

| Variable        | Default | Description                         |
|-----------------|---------|-------------------------------------|
| `MAX_UPLOAD_MB` | `100`   | Maximum total upload size in MB     |
| `RACK_ENV`      | —       | `production` switches logging to `logs/app.log` and uses the venv OCRmyPDF path |

---

## Cron Job (Required for Cleanup)

The application performs a **boot-time cleanup** of job directories older than 6 hours. For routine cleanup during normal operation, add the following cron entry (adjust the path):

```cron
*/10 * * * * find /path/to/app/tmp/jobs -mindepth 1 -maxdepth 1 -type d -mmin +60 -exec rm -rf {} +
```

This removes job directories older than 60 minutes, running every 10 minutes.

**The vault.** Converted files can be downloaded for 1 hour after the job **completes** (`expires_at` in `status.json`). After that the vault is closed and enforced by the server:
- `/download` returns `410 Gone` and deletes the output.
- `/status` reports `vault_closed: true`.

The cron job is the backstop that removes the whole job directory. Every status write bumps the directory's mtime, so its 60-minute age also counts from the last write.

---

## Application Routes

| Method | Path                  | Description                             |
|--------|-----------------------|-----------------------------------------|
| `GET`  | `/`                   | Upload page (main UI)                   |
| `POST` | `/upload`             | Accepts file(s), starts conversion job  |
| `GET`  | `/status/:job_id`     | JSON status of a conversion job (plus `server_time`) |
| `GET`  | `/download/:job_id`   | Download converted file(s); `410` once the vault has closed |

---

## OCRmyPDF Flags Used

```
ocrmypdf \
  --output-type pdfa-2 \
  --rasterizer auto \
  --skip-text \
  --optimize 1 \
  --pdfa-image-compression lossless \
  --color-conversion-strategy RGB \
  --jobs 1 \
  input.pdf output.pdf
```

- `--output-type pdfa-2` — targets PDF/A-2b output via Ghostscript
- `--rasterizer auto` — uses pypdfium2 when available, falls back to pdftoppm
- `--skip-text` — preserves existing text layers; skips pages that already have extractable text
- `--optimize 1` — lossless optimizations only
- `--pdfa-image-compression lossless` — prevents lossy transcoding during the Ghostscript step
- `--color-conversion-strategy RGB` — normalises colour spaces to RGB for PDF/A compliance
- `--jobs 1` — per-file parallelism (multiple files are processed sequentially per job)

### Force archival (opt-in)

Some PDFs contain things Ghostscript can't make PDF/A-compliant. OCRmyPDF still writes a valid PDF, but exits with code 10 ("conversion to PDF/A did not succeed"), and those files fail by default.

If the user ticks **Force archival for difficult files** before uploading, each file that fails this way is retried once with `--force-ocr` instead of `--skip-text`. That rebuilds every page as an image with an OCR text layer, which passes PDF/A far more often. The cost:
- The file is bigger.
- The text is re-read by OCR and can contain mistakes.
- Links, bookmarks and form fields stop working.

Files that convert normally are never forced. Forced files are marked "as images" in the UI and listed under Needs attention.

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
│   ├── style.css       # LeGGacy vault theme (light + dark tokens)
│   └── logo.svg        # Shared toolbox favicon
├── views/
│   └── index.erb       # Upload / progress / vault UI
├── logs/               # app.log in production (git-ignored)
├── tmp/
│   └── jobs/           # Job working directories (auto-cleaned)
└── README.md
```
