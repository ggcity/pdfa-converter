require "sinatra"
require "json"
require "securerandom"
require "fileutils"
require "open3"
require "logger"
require "time"
require "zip"

# Passenger can start the app without a UTF-8 locale (no LANG), and Ruby then
# tags files and tool output as US-ASCII: a non-ASCII PDF title crashed a log
# line with Encoding::CompatibilityError. Treat everything as UTF-8.
Encoding.default_external = Encoding::UTF_8

# Tool output as valid UTF-8. Ghostscript can echo raw PDFDocEncoding bytes
# from DOCINFO; invalid bytes become "?" instead of breaking regex/interpolation.
def utf8(text)
  text.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")
end

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

MAX_UPLOAD_BYTES = (ENV["MAX_UPLOAD_MB"] || 100).to_i * 1024 * 1024
JOBS_DIR         = File.expand_path("tmp/jobs", __dir__)
LOG_DIR          = File.expand_path("logs", __dir__)
JOB_TTL_SECONDS  = 3600       # vault stays open 1 hour after the job completes
BOOT_CLEANUP_AGE = 6 * 3600   # delete on boot if older than 6 hours

# Production (Passenger) appends to logs/app.log; everywhere else logs to stdout.
# No built-in rotation: it isn't safe across Passenger processes; use logrotate.
LOGGER = if ENV["RACK_ENV"] == "production"
  FileUtils.mkdir_p(LOG_DIR)
  log_file = File.open(File.join(LOG_DIR, "app.log"), "a")
  log_file.sync = true
  Logger.new(log_file)
else
  Logger.new($stdout)
end

# Job IDs are download credentials: only ever log a prefix.
def short_id(job_id)
  "#{job_id.to_s[0, 8]}…"
end

# Request logger that shortens job IDs in paths (/status/<uuid>, /download/<uuid>).
class RedactingCommonLogger < Rack::CommonLogger
  UUID_RE = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/

  private

  def log(env, status, *args)
    path = env[Rack::PATH_INFO].to_s
    # The page polls /status every 2s; successful polls are noise. Failures still log.
    return if env[Rack::REQUEST_METHOD] == "GET" && path.start_with?("/status/") && status.to_i < 400
    env  = env.merge(Rack::PATH_INFO => path.gsub(UUID_RE) { |id| short_id(id) }) if path.match?(UUID_RE)
    super(env, status, *args)
  end
end

configure do
  set :bind, "0.0.0.0"
  set :max_request_body_size, MAX_UPLOAD_BYTES
  set :logging, false

  FileUtils.mkdir_p(JOBS_DIR)

  # Boot cleanup: remove stale job directories left by crashes / missed cron
  Dir.glob(File.join(JOBS_DIR, "*")).each do |dir|
    next unless File.directory?(dir)
    age = Time.now - File.mtime(dir)
    if age > BOOT_CLEANUP_AGE
      FileUtils.rm_rf(dir)
      LOGGER.info "[boot-cleanup] Removed stale job #{short_id(File.basename(dir))} (age #{(age / 3600).round(1)}h)"
    end
  end
end

use RedactingCommonLogger, LOGGER

# ---------------------------------------------------------------------------
# status.json helpers
# ---------------------------------------------------------------------------

def job_dir(job_id)
  File.join(JOBS_DIR, job_id)
end

def status_path(job_id)
  File.join(job_dir(job_id), "status.json")
end

# Read the status.json for a job; returns nil if missing/corrupt.
def read_status(job_id)
  path = status_path(job_id)
  return nil unless File.exist?(path)
  JSON.parse(File.read(path))
rescue JSON::ParserError
  nil
end

# Atomically overwrite status.json (write to tmp, then rename).
def write_status(job_id, data)
  path = status_path(job_id)
  tmp  = "#{path}.#{Process.pid}.tmp"
  File.write(tmp, JSON.generate(data))
  File.rename(tmp, path)
end

# The vault closes JOB_TTL_SECONDS after completion; expires_at is nil until then.
def vault_closed?(data)
  return true if data["vault_closed"]
  return false unless data["expires_at"]
  Time.now >= Time.parse(data["expires_at"])
rescue ArgumentError
  false
end

# Delete the converted output and mark the job closed. Safe to call repeatedly.
def close_vault!(job_id, data)
  FileUtils.rm_rf(File.join(job_dir(job_id), "output"))
  return data if data["vault_closed"]
  data["vault_closed"]      = true
  data["download_ready"]    = false
  data["download_filename"] = nil
  write_status(job_id, data)
  LOGGER.info "[vault] Closed job #{short_id(job_id)}"
  data
end

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Strip path-traversal chars and normalise filename.
def sanitize_filename(name)
  name = File.basename(name.to_s.gsub("\\", "/"))
  name = name.gsub(/[^\w\s\-.]/, "_")
  name = name.strip.gsub(/\s+/, "_")
  name = "file" if name.empty? || name == "."
  name
end

# Validate PDF magic bytes.
def valid_pdf?(path)
  File.open(path, "rb") { |f| f.read(5) } == "%PDF-"
rescue
  false
end

# Extract all PDFs from a ZIP into dest_dir, flattening nested directories.
def extract_zip(zip_path, dest_dir)
  extracted = []
  Zip::File.open(zip_path) do |zip|
    zip.each do |entry|
      next if entry.directory?
      next unless entry.name.downcase.end_with?(".pdf")

      safe_name = sanitize_filename(entry.name)
      dest = unique_path(dest_dir, safe_name)
      entry.extract(dest)
      extracted << File.basename(dest)
    end
  end
  extracted
rescue Zip::Error => e
  raise "ZIP extraction failed: #{e.message}"
end

def unique_path(dir, filename)
  base      = File.basename(filename, ".*")
  ext       = File.extname(filename)
  candidate = File.join(dir, filename)
  n = 1
  while File.exist?(candidate)
    candidate = File.join(dir, "#{base}_#{n}#{ext}")
    n += 1
  end
  candidate
end

# ---------------------------------------------------------------------------
# OCRmyPDF
# ---------------------------------------------------------------------------

OCRMYPDF_CMD = if ENV["RACK_ENV"] == "production"
  "/var/www/rails/pdfa-converter/.venv/bin/ocrmypdf"
else
  "ocrmypdf"
end

OCRMYPDF_FLAGS = %w[
  --output-type pdfa-2
  --rasterizer auto
  --skip-text
  --optimize 1
  --pdfa-image-compression lossless
  --color-conversion-strategy RGB
  --jobs 1
].freeze

# ---------------------------------------------------------------------------
# Log helpers: make app.log say *why*, not just "failed"
# ---------------------------------------------------------------------------

# ocrmypdf.ExitCode names, so the log reads "10 pdfa_conversion_failed".
OCRMYPDF_EXIT_NAMES = {
  0 => "ok", 1 => "bad_args", 2 => "input_file", 3 => "missing_dependency",
  4 => "invalid_output_pdf", 5 => "file_access_error", 6 => "already_done_ocr",
  7 => "child_process_error", 8 => "encrypted_pdf", 9 => "invalid_config",
  10 => "pdfa_conversion_failed", 15 => "other_error", 130 => "ctrl_c"
}.freeze

def exit_label(code)
  "#{code.inspect} #{OCRMYPDF_EXIT_NAMES.fetch(code, "unknown")}"
end

# Lines of ocrmypdf stderr worth reading: warnings, errors, Ghostscript and
# PDF/A messages, plus the final few lines. Per-page progress is dropped.
STDERR_DIAG_RE = %r{warn|error|fail|ghostscript|cannot|could not|unable|invalid|
                    not\s(?:supported|allowed|a\s)|pdf/a|xmp|font|transparen|
                    encrypt|signature|colou?r|icc|annotation|embedded}xi

def stderr_digest(stderr, max_lines: 25)
  lines  = stderr.to_s.lines.map(&:rstrip).reject(&:empty?)
  picked = (lines.select { |l| l.match?(STDERR_DIAG_RE) } + lines.last(5)).uniq.last(max_lines)
  return "    | (no output)" if picked.empty?
  picked.map { |l| "    | #{l}" }.join("\n")
end

def human_size(bytes)
  return "?" unless bytes
  return "#{bytes} B" if bytes < 1024
  return format("%.1f KB", bytes / 1024.0) if bytes < 1024 * 1024
  format("%.1f MB", bytes / (1024.0 * 1024))
end

# "PDF 1.7, 2.1 MB" from the header bytes: cheap and useful when triaging.
def describe_pdf(path)
  header  = File.open(path, "rb") { |f| f.read(8) }.to_s
  version = header[/%PDF-(\d\.\d)/, 1]
  "PDF #{version || "?"}, #{human_size(File.size?(path))}"
rescue SystemCallError
  "unreadable"
end

# Where the full ocrmypdf/verapdf output lives, without the full job ID.
def job_log_hint(job_id, filename)
  "full output: tmp/jobs/#{job_id.to_s[0, 8]}*/logs/#{filename}.log"
end

def verapdf_label(result)
  return "unavailable (podman/image missing or file unreadable)" unless result
  return "pass (PDF/A-#{result["profile"]})" if result["result"] == "pass"
  "fail: #{result["details"]}"
end

# "Force archival" retry: rasterize every page and OCR it instead of keeping the
# existing text layer. Only used, when the user opts in, for files whose normal
# conversion ends in EXIT_PDFA_FAILED. (--force-ocr and --skip-text are exclusive.)
OCRMYPDF_FORCE_FLAGS = OCRMYPDF_FLAGS.map { |f| f == "--skip-text" ? "--force-ocr" : f }.freeze
EXIT_PDFA_FAILED     = 10   # output is a valid PDF, but not PDF/A

# The Python that runs ocrmypdf (the venv's in production), so pikepdf is available.
OCRMYPDF_PYTHON = if ENV["RACK_ENV"] == "production"
  File.join(File.dirname(OCRMYPDF_CMD), "python")
else
  "python3"
end

# Ghostscript 9.54 (RHEL 9) can't carry non-ASCII DOCINFO text (e.g. an en dash
# in /Title) into PDF/A XMP: it discards DOCINFO and the PDF/A marker with it,
# so ocrmypdf exits 10 "No PDF/A metadata in XMP". This writes a copy whose
# DOCINFO text is plain ASCII; page content is untouched. Prints one line per
# changed field, and writes nothing when there is nothing to change.
PLAIN_DOCINFO_PY = <<~'PY'
  import sys, unicodedata, pikepdf
  src, dst = sys.argv[1], sys.argv[2]
  MAP = {"\u2010": "-", "\u2011": "-", "\u2012": "-", "\u2013": "-", "\u2014": "-", "\u2212": "-",
         "\u2018": "'", "\u2019": "'", "\u201a": "'", "\u201c": '"', "\u201d": '"', "\u201e": '"',
         "\u2026": "...", "\u2022": "*", "\u00a0": " ", "\u00a9": "(C)", "\u00ae": "(R)", "\u2122": "(TM)"}
  def plain(s):
      s = "".join(MAP.get(c, c) for c in s)
      return unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode()
  changed = []
  with pikepdf.open(src) as pdf:
      for key in list(pdf.docinfo.keys()):
          value = pdf.docinfo[key]
          if isinstance(value, pikepdf.String):
              text = str(value)
              if any(ord(c) > 127 for c in text):
                  pdf.docinfo[key] = plain(text)
                  changed.append(f"{key}: {text!r} -> {plain(text)!r}")
      if changed:
          pdf.save(dst)
  print("\n".join(changed))
PY

# Returns [path_of_plain_copy_or_nil, "description of changes"].
def plain_docinfo_copy(input_path, work_dir)
  FileUtils.mkdir_p(work_dir)
  dst = File.join(work_dir, File.basename(input_path))
  out, err, st = Open3.capture3(OCRMYPDF_PYTHON, "-c", PLAIN_DOCINFO_PY, input_path, dst)
  out, err = utf8(out), utf8(err)
  return [nil, "could not rewrite metadata: #{(err.strip.lines.last || "exit #{st.exitstatus}").strip}"] unless st.success?
  return [nil, "no non-ASCII document info to simplify"] unless File.exist?(dst)
  [dst, out.strip]
rescue SystemCallError => e
  [nil, "could not run #{OCRMYPDF_PYTHON}: #{e.message}"]
end

# Record which tool versions this worker uses (in the background: --version is slow).
# Ghostscript does the PDF/A step (--pdfa-image-compression rules out OCRmyPDF's
# pikepdf-only route), so its version and path matter most when dev and prod differ.
# Passenger's PATH can differ from a login shell's, hence the resolved paths.
Thread.new do
  version = lambda do |*cmd|
    out, st = Open3.capture2e(*cmd)
    out = utf8(out)
    st.success? ? out.strip.lines.first.to_s.strip : "error (#{out.strip.lines.last.to_s.strip})"
  rescue SystemCallError
    "not found"
  end
  which = lambda do |cmd|
    return cmd if cmd.include?("/")
    dir = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).find { |d| File.executable?(File.join(d, cmd)) }
    dir ? File.join(dir, cmd) : "not on PATH"
  end
  # The Python that runs ocrmypdf: the venv's in production, python3 otherwise
  pylibs = version.call(OCRMYPDF_PYTHON, "-c",
    "import sys, pikepdf; print('python', sys.version.split()[0], 'pikepdf', pikepdf.__version__, 'qpdf', pikepdf.__libqpdf_version__)")
  LOGGER.info "[boot] pid #{Process.pid}, RACK_ENV=#{ENV["RACK_ENV"] || "development"}, ruby #{RUBY_VERSION}\n" \
              "    ocrmypdf    #{version.call(OCRMYPDF_CMD, "--version")} (#{which.call(OCRMYPDF_CMD)})\n" \
              "    #{pylibs}\n" \
              "    ghostscript #{version.call("gs", "--version")} (#{which.call("gs")})\n" \
              "    #{version.call("tesseract", "--version")} (#{which.call("tesseract")})\n" \
              "    PATH=#{ENV["PATH"]}"
end

def run_ocrmypdf(input_path, output_path, log_path, force: false)
  flags = force ? OCRMYPDF_FORCE_FLAGS : OCRMYPDF_FLAGS
  cmd = [OCRMYPDF_CMD, *flags, input_path, output_path]
  stdout, stderr, status = Open3.capture3(*cmd)
  stdout, stderr = utf8(stdout), utf8(stderr)
  heading = force ? "OCRMYPDF (forced as page images)" : "OCRMYPDF"
  File.open(log_path, "a") { |f| f.write("\n\n#{heading}\nSTDOUT:\n#{stdout}\n\nSTDERR:\n#{stderr}\n") }
  [status.exitstatus, stderr]
end

# Run verapdf via podman to verify PDF/A conformance.
# Returns { "result" => "pass", "profile" => "2b" },
#         { "result" => "fail", "details" => "..." },
#      or nil if podman / the image is unavailable (skip silently).
def run_verapdf(output_path, log_path)
  dir      = File.dirname(output_path)
  filename = File.basename(output_path)

  cmd = [
    "podman", "run", "--rm",
    "-v", "#{dir}:/data:ro",
    "verapdf/cli",
    "--format", "text",
    "/data/#{filename}"
  ]

  stdout, stderr, _status = Open3.capture3(*cmd)
  stdout, stderr = utf8(stdout), utf8(stderr)
  File.open(log_path, "a") { |f| f.write("\n\nVERAPDF:\n#{stdout}#{stderr}") }

  first_line = stdout.lines.first.to_s.strip
  if first_line.start_with?("PASS")
    profile = first_line.split[2]   # e.g. "2b"
    { "result" => "pass", "profile" => profile }
  elsif first_line.empty?
    nil   # podman/image unavailable: skip silently
  else
    { "result" => "fail", "details" => first_line }
  end
rescue Errno::ENOENT
  nil   # podman not on PATH: skip silently
end

# ---------------------------------------------------------------------------
# Background processing
# ---------------------------------------------------------------------------

def process_job(job_id)
  in_dir  = File.join(job_dir(job_id), "input")
  out_dir = File.join(job_dir(job_id), "output")
  log_dir = File.join(job_dir(job_id), "logs")
  FileUtils.mkdir_p([out_dir, log_dir])

  job_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  initial = read_status(job_id)
  # Only process files that are queued (not rejected)
  filenames = initial["files"].reject { |f| f["status"] == "rejected" }.map { |f| f["name"] }

  filenames.each do |filename|
    # Mark current file as processing
    data  = read_status(job_id)
    entry = data["files"].find { |f| f["name"] == filename }
    entry["status"]    = "processing"
    data["current_file"] = filename
    write_status(job_id, data)

    input_path  = File.join(in_dir, filename)
    output_path = File.join(out_dir, filename)
    log_path    = File.join(log_dir, "#{filename}.log")

    tag = "[job #{short_id(job_id)}] #{filename}"
    LOGGER.info "#{tag}: starting (#{describe_pdf(input_path)})"

    # Skip conversion if the file is already PDF/A-2b conformant
    pre_check = run_verapdf(input_path, log_path)
    LOGGER.info "#{tag}: verapdf pre-check #{verapdf_label(pre_check)}"
    if pre_check && pre_check["result"] == "pass" && pre_check["profile"] == "2b"
      FileUtils.cp(input_path, output_path)
      data  = read_status(job_id)
      entry = data["files"].find { |f| f["name"] == filename }
      entry["status"]          = "done"
      entry["error"]           = nil
      entry["skipped"]         = true
      entry["pdfa_validation"] = pre_check
      data["completed_files"] += 1
      write_status(job_id, data)
      LOGGER.info "#{tag}: already PDF/A-2b, passed through unchanged"
      next
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    LOGGER.info "#{tag}: running ocrmypdf #{OCRMYPDF_FLAGS.join(" ")}"
    exit_code, stderr = run_ocrmypdf(input_path, output_path, log_path)
    forced          = false
    docinfo_changes = nil
    retry_input     = input_path

    # Retry 1 (automatic, content untouched): plain-ASCII document info
    if exit_code == EXIT_PDFA_FAILED
      LOGGER.warn "#{tag}: normal conversion ended #{exit_label(exit_code)}; ocrmypdf said:\n#{stderr_digest(stderr)}"
      plain_path, note = plain_docinfo_copy(input_path, File.join(job_dir(job_id), "work"))
      if plain_path
        LOGGER.info "#{tag}: retrying with plain-ASCII document info:\n#{note.lines.map { |l| "    | #{l.rstrip}" }.join("\n")}"
        exit_code, stderr = run_ocrmypdf(plain_path, output_path, log_path)
        docinfo_changes = note
        retry_input     = plain_path
        if exit_code == EXIT_PDFA_FAILED
          LOGGER.warn "#{tag}: plain-document-info retry also ended #{exit_label(exit_code)}; ocrmypdf said:\n#{stderr_digest(stderr)}"
        end
      else
        LOGGER.info "#{tag}: no plain-document-info retry (#{note})"
      end
    end

    # Retry 2 (last resort, only when the user opted in): pages as images
    if exit_code == EXIT_PDFA_FAILED && initial["force_image"]
      LOGGER.info "#{tag}: force archival is on, retrying as page images: ocrmypdf #{OCRMYPDF_FORCE_FLAGS.join(" ")}"
      exit_code, stderr = run_ocrmypdf(retry_input, output_path, log_path, force: true)
      forced = true
    end
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)

    # Read fresh copy, update result
    data  = read_status(job_id)
    entry = data["files"].find { |f| f["name"] == filename }

    # Exit code 6 = "already has OCR text": treated as success with --skip-text
    if exit_code == 0 || exit_code == 6
      entry["status"]          = "done"
      entry["error"]           = nil
      entry["forced_image"]    = forced
      entry["docinfo_simplified"] = !docinfo_changes.nil?
      entry["pdfa_validation"] = run_verapdf(output_path, log_path)
      data["completed_files"] += 1
      how = if forced then "forced as page images"
            elsif docinfo_changes then "normal, with plain-ASCII document info"
            else "normal"
            end
      LOGGER.info "#{tag}: converted in #{elapsed}s (#{how}, exit #{exit_label(exit_code)}), " \
                  "output #{describe_pdf(output_path)}, verapdf post-check #{verapdf_label(entry["pdfa_validation"])}"
    else
      short_err = stderr.lines.last(5).join.strip
      entry["status"]       = "failed"
      entry["error"]        = short_err
      entry["exit_code"]    = exit_code
      entry["forced_image"] = forced
      entry["docinfo_simplified"] = !docinfo_changes.nil?
      data["completed_files"] += 1
      data["failed_files"]    += 1
      FileUtils.rm_f(output_path)   # a non-archival leftover must not end up in the download
      context = if forced
        "even after the forced page-image retry"
      elsif exit_code == EXIT_PDFA_FAILED
        "#{docinfo_changes ? "also after the plain-document-info retry; " : ""}force archival was off, so no page-image retry"
      else
        "no retry for this exit code"
      end
      LOGGER.warn "#{tag}: FAILED in #{elapsed}s, exit #{exit_label(exit_code)} (#{context}); ocrmypdf said:\n" \
                  "#{stderr_digest(stderr)}\n    #{job_log_hint(job_id, filename)}"
    end

    write_status(job_id, data)
  end

  # Determine overall outcome
  data       = read_status(job_id)
  all_files  = data["files"]
  done_files = all_files.select { |f| f["status"] == "done" }

  if done_files.empty?
    data["status"]            = "failed"
    data["current_file"]      = nil
    data["download_ready"]    = false
    data["download_filename"] = nil
    write_status(job_id, data)
  else
    if done_files.size == 1
      download_filename = done_files.first["name"]
    else
      download_filename = "converted_files.zip"
      zip_path = File.join(out_dir, download_filename)
      Zip::OutputStream.open(zip_path) do |zos|
        done_files.each do |f|
          pdf_path = File.join(out_dir, f["name"])
          next unless File.exist?(pdf_path)
          zos.put_next_entry(f["name"])
          zos.write(File.binread(pdf_path))
        end
      end
      # Remove individual PDFs; only the ZIP remains
      done_files.each { |f| FileUtils.rm_f(File.join(out_dir, f["name"])) }
    end

    now = Time.now.utc
    data["status"]            = "complete"
    data["current_file"]      = nil
    data["download_ready"]    = true
    data["download_filename"] = download_filename
    data["download_size"]     = File.size(File.join(out_dir, download_filename))
    data["completed_at"]      = now.iso8601
    data["expires_at"]        = (now + JOB_TTL_SECONDS).iso8601
    write_status(job_id, data)
  end
  total_s  = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - job_started).round(1)
  download = data["download_filename"] ? ", download #{data["download_filename"]} (#{human_size(data["download_size"])})" : ""
  LOGGER.info "[job #{short_id(job_id)}] Finished in #{total_s}s: #{data["status"]}, " \
              "#{done_files.size} done, #{data["failed_files"]} failed#{download}"
rescue => e
  LOGGER.error "[job-error] #{short_id(job_id)} #{e.class}: #{e.message}\n  #{Array(e.backtrace).first(5).join("\n  ")}"
  begin
    data = read_status(job_id) || {}
    # Don't leave records stuck at "processing"/"queued" under a failed job
    Array(data["files"]).each do |f|
      next unless %w[processing queued].include?(f["status"])
      f["status"] = "failed"
      f["error"]  = "Conversion stopped unexpectedly"
    end
    data["status"]            = "failed"
    data["current_file"]      = nil
    data["download_ready"]    = false
    data["download_filename"] = nil
    write_status(job_id, data)
  rescue
    # Best-effort; if we can't write, nothing we can do
  end
end

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

get "/" do
  erb :index
end

post "/upload" do
  content_type :json

  uploaded_files = params[:files]
  uploaded_files = [uploaded_files] unless uploaded_files.is_a?(Array)
  uploaded_files = uploaded_files.compact

  if uploaded_files.empty?
    halt 400, { error: "No files uploaded." }.to_json
  end

  job_id = SecureRandom.uuid
  in_dir = File.join(job_dir(job_id), "input")
  FileUtils.mkdir_p(in_dir)

  collected_names = []
  rejections      = []

  uploaded_files.each do |upload|
    next unless upload.is_a?(Hash) && upload[:filename]

    raw_name = upload[:filename].to_s
    tmp_path = upload[:tempfile].path

    if raw_name.downcase.end_with?(".zip")
      begin
        names = extract_zip(tmp_path, in_dir)
        collected_names.concat(names)
      rescue => e
        rejections << { "name" => raw_name, "reason" => e.message }
      end
    elsif raw_name.downcase.end_with?(".pdf")
      safe_name = sanitize_filename(raw_name)
      dest = unique_path(in_dir, safe_name)
      FileUtils.cp(tmp_path, dest)
      collected_names << File.basename(dest)
    else
      rejections << { "name" => raw_name, "reason" => "Unsupported file type (only .pdf and .zip are accepted)" }
    end
  end

  # Validate PDF magic bytes
  file_records = []
  collected_names.each do |name|
    path = File.join(in_dir, name)
    if valid_pdf?(path)
      # Uploads arrive 0600 (copied from Rack's tempfile); the verapdf container
      # runs as a non-root user and can't read them, which silently disables the
      # already-PDF/A pre-check. Outputs from ocrmypdf are 0644 already.
      File.chmod(0o644, path)
      file_records << { "name" => name, "status" => "queued", "error" => nil }
    else
      FileUtils.rm_f(path)
      file_records << { "name" => name, "status" => "rejected", "error" => "Not a valid PDF (bad magic bytes)" }
      rejections   << { "name" => name, "reason" => "Not a valid PDF (bad magic bytes)" }
    end
  end

  # Add rejection records for files that never made it to collected_names
  rejections.each do |r|
    unless file_records.any? { |f| f["name"] == r["name"] }
      file_records << { "name" => r["name"], "status" => "rejected", "error" => r["reason"] }
    end
  end

  processable = file_records.count { |f| f["status"] == "queued" }
  if processable == 0
    FileUtils.rm_rf(job_dir(job_id))
    halt 422, { error: "No valid PDF files to process.", details: rejections }.to_json
  end

  now = Time.now.utc
  initial_status = {
    "job_id"            => job_id,
    "status"            => "processing",
    "force_image"       => params[:force_image] == "1",
    "total_files"       => processable,
    "completed_files"   => 0,
    "failed_files"      => 0,
    "current_file"      => nil,
    "created_at"        => now.iso8601,
    "completed_at"      => nil,
    "expires_at"        => nil,   # set when the job completes
    "vault_closed"      => false,
    "files"             => file_records,
    "download_ready"    => false,
    "download_filename" => nil,
    "download_size"     => nil
  }
  write_status(job_id, initial_status)
  listing = file_records.first(10).map do |f|
    f["status"] == "queued" ? f["name"] : "#{f["name"]} (rejected: #{f["error"]})"
  end
  listing << "… #{file_records.size - 10} more" if file_records.size > 10
  LOGGER.info "[job #{short_id(job_id)}] Accepted from #{request.ip}: #{processable} queued, " \
              "#{file_records.size - processable} rejected, force archival #{initial_status["force_image"] ? "ON" : "off"}\n" \
              "#{listing.map { |l| "    - #{l}" }.join("\n")}"

  Thread.new { process_job(job_id) }

  { job_id: job_id }.to_json
end

get "/status/:job_id" do
  content_type :json

  job_id = params[:job_id]
  unless job_id =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    halt 400, { error: "Invalid job ID format." }.to_json
  end

  data = read_status(job_id)
  halt 404, { error: "Job not found." }.to_json unless data

  data = close_vault!(job_id, data) if data["status"] == "complete" && vault_closed?(data)

  # server_time lets the client run the vault countdown without trusting its own clock
  data.merge("server_time" => Time.now.utc.iso8601).to_json
end

get "/download/:job_id" do
  job_id = params[:job_id]
  unless job_id =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    halt 400, "Invalid job ID format."
  end

  status = read_status(job_id)
  if status && vault_closed?(status)
    close_vault!(job_id, status)
    LOGGER.info "[download] Refused #{short_id(job_id)}: vault closed"
    halt 410, "The vault is closed. These converted files were deleted from the server."
  end

  out_dir = File.join(job_dir(job_id), "output")
  unless File.directory?(out_dir)
    halt 404, "This file is no longer available."
  end

  unless status && status["download_ready"] && status["download_filename"]
    halt 404, "This file is no longer available."
  end

  file_path = File.join(out_dir, status["download_filename"])
  unless File.exist?(file_path)
    halt 404, "This file is no longer available."
  end

  LOGGER.info "[download] Served #{short_id(job_id)} (#{status["download_filename"]})"
  send_file file_path, filename: status["download_filename"], disposition: "attachment"
end
