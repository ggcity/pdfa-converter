# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**PDF LeGGacy** is a single-file Sinatra app (`app.rb`, classic style) that wraps OCRmyPDF (v17+) to batch-convert uploaded PDFs, or ZIPs of PDFs, to PDF/A-2b. It belongs to the GG IT Toolbox family. The toolbox is a separate Firebase repo at `/var/www/firebase/gg-toolbox`; its launcher tile and `/leggacy` redirect point here.

- **Production:** Phusion Passenger at `https://ch.ggcity.org/pdfa-converter`, with `RACK_ENV=production`.
- **Frontend:** `views/index.erb` (plain HTML with vanilla JS, no framework) plus `public/style.css`.
- **Look:** `design-spec.html` is the design handoff spec. It's a bundled page; decode the `__bundler/template` JSON to read it. The family header, back arrow, contact button and theme switch come from the toolbox's `PDF MERGGER/index.html`.
- **Other docs:** `PLAN.md` is the original functional spec. `README.md` covers system dependencies, Passenger notes, logging, and the vault and cron setup.

## Commands

```bash
bundle install
bundle exec ruby app.rb                                      # dev server on 0.0.0.0:4567, logs to stdout
RACK_ENV=production bundle exec puma config.ru -p 4567      # production-like: logs to logs/app.log, venv ocrmypdf path
MAX_UPLOAD_MB=200 bundle exec ruby app.rb                    # override upload limit (default 100)
```

There is no test suite, linter, or build step. Use `ruby -c app.rb` for a syntax check.

External tools that must be on the host: `ocrmypdf`, Ghostscript, and Tesseract. Podman with the `verapdf/cli` image is optional.

## Architecture

**Jobs live on the filesystem; there is no database or queue.** Each upload gets a `SecureRandom.uuid` job ID and a directory `tmp/jobs/<uuid>/` containing `input/`, `output/`, `logs/`, and `status.json`. `status.json` is the only record of job state:
- `POST /upload` writes it.
- A background `Thread.new { process_job }` in the same worker process updates it. Under Passenger, killing or restarting that process kills the job; see the README.
- `GET /status/:job_id` parses it, lazily closes the vault if it has expired, and adds `server_time`.
- `GET /download/:job_id` reads `download_filename` from it.

Always change `status.json` through `read_status`/`write_status`. `write_status` writes to a temp file and renames it so the change is atomic. `process_job` re-reads the status before each update instead of keeping a copy in memory. Keep doing both.

**What happens to each file in `process_job`:**
1. **verapdf pre-check.** If the input already passes PDF/A-2b, it is copied to `output/` unchanged and marked `skipped: true`.
2. **Otherwise, run `ocrmypdf` with `OCRMYPDF_FLAGS`.** Exit codes 0 and 6 both count as success; 6 means the file already has text (`--skip-text`). On failure, `exit_code` is stored with `error`. The UI maps 8 to password-protected and 2 to a damaged input.
3. **verapdf post-check.** The result is stored in `pdfa_validation`.

When the job finishes: if exactly one file converted, it is served as-is. If more than one did, they are zipped into `converted_files.zip` and the individual PDFs are deleted. Completion also sets `completed_at`, `download_size`, and `expires_at`.

**The vault (the download window):**
- `expires_at` stays `nil` until the job completes. After that it is `JOB_TTL_SECONDS` (1 hour) later.
- `vault_closed?` and `close_vault!` enforce it on the server. `/download` returns 410 and deletes `output/`, and status gets `vault_closed: true`.
- The UI runs its countdown from `expires_at - server_time`, so the client clock doesn't matter.

**verapdf is optional.** `run_verapdf` runs `podman run verapdf/cli`. It returns `nil` when podman or the image is missing, and callers must treat `nil` as "skip", not as a failure. The UI shows `nil` as "Converted · not checked" and counts it under "Check failed".

**Logging:** everything goes through `LOGGER`. In production that's `logs/app.log`, appended with sync and no in-process rotation because of multiple Passenger processes. Everywhere else it's stdout. `Rack::CommonLogger` sends request lines to the same logger. Log job IDs only through `short_id`.

**Environment-dependent paths:**
- With `RACK_ENV=production`, `OCRMYPDF_CMD` points at `/var/www/rails/pdfa-converter/.venv/bin/ocrmypdf`. In dev it is plain `ocrmypdf` on PATH.
- The app is mounted under a sub-path. Build every URL in views and JS from `request.script_name` (exposed to JS as `BASE_PATH`), never from a hard-coded `/`. Links back to the toolbox are absolute (`https://toolbox.ggcity.org/`).

**Frontend conventions (from the design spec):**
- The UI's states are Accession (`#upload-section`), Preserving (`#progress-section`), In the vault (`#download-area`), and a dead-end card (`#dead-end`, which covers failed jobs, a closed vault, and upload errors). Only one state is on screen at a time.
- Keep the existing element ids.
- Show and hide with the local `.d-none` class. There is no Bootstrap.
- No emoji or unicode icons: use the pixel SVGs, type chips, and stamps.
- Themes use `data-theme="dark"` on `<html>`, stored in localStorage key `leggacy_theme`. Every color is a CSS token defined in both `:root` and `[data-theme="dark"]`.
- Motion budget: the shelf steps, the drop-zone lid lifts, buttons press, and the countdown ticks. Nothing else moves, and `prefers-reduced-motion` is honored.

**Security rules to keep:**
- The job UUID is the only access credential. Validate it against the UUID regex on every route, and log at most its first 8 characters.
- Sanitize filenames with `sanitize_filename`. ZIP entries are flattened into `input/`, and name collisions are resolved with `unique_path`.
- Check `%PDF-` magic bytes regardless of the file extension.
- Serve output only through `/download`, never as static files.
- There is no authentication yet. The toolbox STAFF GATE and `recordsPreserved` stats reporting are deferred, because they need credentialed CORS for `https://ch.ggcity.org` in the toolbox's Cloud Function.

**Cleanup:** At boot, job dirs older than 6 hours are deleted. Routine cleanup (older than 60 minutes) relies on an external cron job described in the README.
