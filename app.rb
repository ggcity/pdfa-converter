require "sinatra"
require "json"
require "securerandom"
require "fileutils"
require "open3"
require "logger"
require "time"
require "zip"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

MAX_UPLOAD_BYTES = (ENV["MAX_UPLOAD_MB"] || 100).to_i * 1024 * 1024
JOBS_DIR         = File.expand_path("tmp/jobs", __dir__)
LOG_DIR          = File.expand_path("logs", __dir__)
JOB_TTL_SECONDS  = 3600       # vault stays open 1 hour after the job completes
BOOT_CLEANUP_AGE = 6 * 3600   # delete on boot if older than 6 hours

# Production (Passenger) appends to logs/app.log; everywhere else logs to stdout.
# No built-in rotation — it isn't safe across Passenger processes; use logrotate.
LOGGER = if ENV["RACK_ENV"] == "production"
  FileUtils.mkdir_p(LOG_DIR)
  log_file = File.open(File.join(LOG_DIR, "app.log"), "a")
  log_file.sync = true
  Logger.new(log_file)
else
  Logger.new($stdout)
end

# Job IDs are download credentials — only ever log a prefix.
def short_id(job_id)
  "#{job_id.to_s[0, 8]}…"
end

# Request logger that shortens job IDs in paths (/status/<uuid>, /download/<uuid>).
class RedactingCommonLogger < Rack::CommonLogger
  UUID_RE = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/

  private

  def log(env, *args)
    path = env[Rack::PATH_INFO].to_s
    env  = env.merge(Rack::PATH_INFO => path.gsub(UUID_RE) { |id| short_id(id) }) if path.match?(UUID_RE)
    super(env, *args)
  end
end

configure do
  set :bind, "0.0.0.0"
  set :max_request_body_size, MAX_UPLOAD_BYTES
  set :logging, false

  FileUtils.mkdir_p(JOBS_DIR)

  # Boot cleanup — remove stale job directories left by crashes / missed cron
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

# "Force archival" retry: rasterize every page and OCR it instead of keeping the
# existing text layer. Only used, when the user opts in, for files whose normal
# conversion ends in EXIT_PDFA_FAILED. (--force-ocr and --skip-text are exclusive.)
OCRMYPDF_FORCE_FLAGS = OCRMYPDF_FLAGS.map { |f| f == "--skip-text" ? "--force-ocr" : f }.freeze
EXIT_PDFA_FAILED     = 10   # output is a valid PDF, but not PDF/A

def run_ocrmypdf(input_path, output_path, log_path, force: false)
  flags = force ? OCRMYPDF_FORCE_FLAGS : OCRMYPDF_FLAGS
  cmd = [OCRMYPDF_CMD, *flags, input_path, output_path]
  stdout, stderr, status = Open3.capture3(*cmd)
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
  File.open(log_path, "a") { |f| f.write("\n\nVERAPDF:\n#{stdout}#{stderr}") }

  first_line = stdout.lines.first.to_s.strip
  if first_line.start_with?("PASS")
    profile = first_line.split[2]   # e.g. "2b"
    { "result" => "pass", "profile" => profile }
  elsif first_line.empty?
    nil   # podman/image unavailable — skip silently
  else
    { "result" => "fail", "details" => first_line }
  end
rescue Errno::ENOENT
  nil   # podman not on PATH — skip silently
end

# ---------------------------------------------------------------------------
# Background processing
# ---------------------------------------------------------------------------

def process_job(job_id)
  in_dir  = File.join(job_dir(job_id), "input")
  out_dir = File.join(job_dir(job_id), "output")
  log_dir = File.join(job_dir(job_id), "logs")
  FileUtils.mkdir_p([out_dir, log_dir])

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

    # Skip conversion if the file is already PDF/A-2b conformant
    pre_check = run_verapdf(input_path, log_path)
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
      LOGGER.info "[job #{short_id(job_id)}] #{filename}: already PDF/A-2b, skipped conversion"
      next
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    exit_code, stderr = run_ocrmypdf(input_path, output_path, log_path)
    forced = false
    if exit_code == EXIT_PDFA_FAILED && initial["force_image"]
      LOGGER.info "[job #{short_id(job_id)}] #{filename}: PDF/A failed, retrying as page images"
      exit_code, stderr = run_ocrmypdf(input_path, output_path, log_path, force: true)
      forced = true
    end
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)

    # Read fresh copy, update result
    data  = read_status(job_id)
    entry = data["files"].find { |f| f["name"] == filename }

    # Exit code 6 = "already has OCR text" — treated as success with --skip-text
    if exit_code == 0 || exit_code == 6
      entry["status"]          = "done"
      entry["error"]           = nil
      entry["forced_image"]    = forced
      entry["pdfa_validation"] = run_verapdf(output_path, log_path)
      data["completed_files"] += 1
      check = entry["pdfa_validation"] ? entry["pdfa_validation"]["result"] : "unchecked"
      how   = forced ? ", forced as page images" : ""
      LOGGER.info "[job #{short_id(job_id)}] #{filename}: converted (exit #{exit_code}, #{elapsed}s#{how}, verapdf #{check})"
    else
      short_err = stderr.lines.last(5).join.strip
      entry["status"]       = "failed"
      entry["error"]        = short_err
      entry["exit_code"]    = exit_code
      entry["forced_image"] = forced
      data["completed_files"] += 1
      data["failed_files"]    += 1
      FileUtils.rm_f(output_path)   # a non-archival leftover must not end up in the download
      LOGGER.warn "[job #{short_id(job_id)}] #{filename}: failed (exit #{exit_code}, #{elapsed}s#{forced ? ", after forced retry" : ""})"
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
  LOGGER.info "[job #{short_id(job_id)}] Finished: #{data["status"]} (#{done_files.size} done, #{data["failed_files"]} failed)"
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
  LOGGER.info "[job #{short_id(job_id)}] Accepted: #{processable} queued, #{file_records.size - processable} rejected" \
              "#{initial_status["force_image"] ? ", force archival on" : ""}"

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
