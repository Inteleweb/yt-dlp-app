bash -c '
set -euo pipefail

sudo mkdir -p /opt/ytui/static
sudo chown -R "$USER":"$USER" /opt/ytui

cat > /opt/ytui/requirements.txt <<EOF
Flask==3.0.3
Werkzeug==3.0.3
EOF

cat > /opt/ytui/app.py <<'\EOF'
#!/usr/bin/env python3
import os, re, json, shlex, signal, threading, queue, subprocess, time, pathlib
from flask import Flask, request, Response, send_from_directory, jsonify

# ---------- Config ----------
HOST = "0.0.0.0"
PORT = 8080
STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")
DEFAULT_DOWNLOAD_DIRS = [
    "/media/pi", "/media/usb", "/mnt", "/home/pi/Downloads", "/srv/downloads"
]
YTDLP_BIN = "yt-dlp"  # ensure installed on Pi
LOG_HISTORY_MAX = 2000  # lines buffered for late subscribers

app = Flask(__name__, static_folder=STATIC_DIR, static_url_path="/static")

# ---------- State ----------
proc_lock = threading.Lock()
current_proc = {"p": None, "start_ts": None, "args": None, "raw": False}
subscribers = set()  # set[queue.Queue]
history = []  # in-memory log ring
history_lock = threading.Lock()

percent_regex = re.compile(r"\[download\]\s+(\d+(?:\.\d+)?)%")

def broadcast(line: str):
    line = line.rstrip("\n")
    with history_lock:
        history.append(line)
        if len(history) > LOG_HISTORY_MAX:
            history[:] = history[-LOG_HISTORY_MAX:]
    dead = []
    for q in list(subscribers):
        try:
            q.put_nowait(line)
        except Exception:
            dead.append(q)
    for q in dead:
        subscribers.discard(q)

def sse_stream():
    q = queue.Queue(maxsize=1000)
    # push history to new subscriber
    with history_lock:
        for ln in history[-500:]:
            try:
                q.put_nowait(ln)
            except Exception:
                break
    subscribers.add(q)
    try:
        while True:
            line = q.get()
            yield f"data: {line}\n\n"
    except GeneratorExit:
        pass
    finally:
        subscribers.discard(q)

def build_args_from_form(data: dict):
    url = data.get("url", "").strip()
    if not url:
        raise ValueError("Missing URL")
    args = [YTDLP_BIN, "--newline"]
    # Destination path
    out_tmpl = data.get("output_template", "").strip()
    if out_tmpl:
        args += ["-o", out_tmpl]
    # Archive
    arch = data.get("archive_path", "").strip()
    if arch:
        args += ["--download-archive", arch]
    # Format
    mode = data.get("format_mode", "preset")  # preset | custom
    if mode == "custom":
        cf = data.get("custom_format", "").strip()
        if cf:
            args += ["-f", cf]
    else:
        # UI booleans produce constraints for 720/1080, audio-only etc.
        dl_kind = data.get("dl_kind", "video_audio")  # video_audio | video | audio
        max_height = str(data.get("max_height") or "").strip()
        if dl_kind == "audio":
            args += ["-f", "bestaudio/best"]
        elif dl_kind == "video":
            if max_height:
                args += ["-f", f"bestvideo*[height<={max_height}]/bestvideo"]
            else:
                args += ["-f", "bestvideo"]
        else:
            if max_height:
                args += ["-f", f"bestvideo*[height<={max_height}]+bestaudio/best[height<={max_height}]/best"]
            else:
                args += ["-f", "bestvideo+bestaudio/best"]
    # Rate & sleep
    limit_rate = data.get("limit_rate", "").strip()
    if limit_rate:
        args += ["--limit-rate", limit_rate]
    sleep_i = str(data.get("sleep_interval") or "").strip()
    sleep_max = str(data.get("max_sleep_interval") or "").strip()
    if sleep_i:
        args += ["--sleep-interval", sleep_i]
    if sleep_max:
        args += ["--max-sleep-interval", sleep_max]
    # Boolean toggles
    toggles = data.get("toggles", [])
    allowed = {
        "--no-abort-on-error", "--skip-unavailable-fragments", "--continue",
        "--restrict-filenames", "--windows-filenames",
        "--embed-thumbnail", "--embed-metadata", "--embed-chapters",
        "--write-description", "--write-info-json", "--no-clean-info-json",
        "--write-subs", "--no-simulate", "--no-ignore-no-formats-error",
        "--list-formats", "--list-subs", "--progress", "--console-title",
        "--no-keep-fragments"
    }
    for t in toggles:
        if t in allowed:
            args.append(t)
    # Destination directory convenience
    base_dir = data.get("destination_dir", "").strip()
    if base_dir and not out_tmpl:
        # Safe default template if none provided
        args += ["-o", os.path.join(base_dir, "%(uploader)s/%(title)s.%(ext)s")]
    # URL last
    args.append(url)
    return args

def spawn_process(args, raw=False):
    with proc_lock:
        if current_proc["p"] is not None:
            raise RuntimeError("Another task is running")
        broadcast(f"# Starting: {' '.join(shlex.quote(a) for a in args)}")
        p = subprocess.Popen(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=1,
            universal_newlines=True,
            preexec_fn=os.setsid
        )
        current_proc.update({"p": p, "start_ts": time.time(), "args": args, "raw": False})
    def reader():
        try:
            for line in p.stdout:
                broadcast(line.rstrip("\n"))
        finally:
            rc = p.wait()
            broadcast(f"# Finished with exit code {rc}")
            with proc_lock:
                current_proc.update({"p": None, "start_ts": None, "args": None, "raw": False})
    threading.Thread(target=reader, daemon=True).start()

# ---------- Routes ----------
from flask import send_file  # optional import kept minimal

@app.route("/")
def index():
    return send_from_directory(STATIC_DIR, "index.html")

@app.route("/api/start", methods=["POST"])
def api_start():
    data = request.get_json(force=True, silent=False) or {}
    try:
        args = build_args_from_form(data)
        spawn_process(args, raw=False)
        return jsonify({"status": "started"})
    except Exception as e:
        return jsonify({"error": str(e)}), 400

@app.route("/api/run_raw", methods=["POST"])
def api_run_raw():
    data = request.get_json(force=True) or {}
    cmd = data.get("cmd", "").strip()
    if not cmd:
        return jsonify({"error": "Missing cmd"}), 400
    try:
        args = shlex.split(cmd)
        spawn_process(args, raw=True)
        return jsonify({"status": "started"})
    except Exception as e:
        return jsonify({"error": str(e)}), 400

@app.route("/api/stop", methods=["POST"])
def api_stop():
    with proc_lock:
        p = current_proc["p"]
        if p is None:
            return jsonify({"status": "idle"})
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGINT)
        except ProcessLookupError:
            pass
    return jsonify({"status": "stopping"})

@app.route("/api/status")
def api_status():
    with proc_lock:
        running = current_proc["p"] is not None
        args = current_proc["args"]
        started = current_proc["start_ts"]
    return jsonify({"running": running, "args": args, "start_ts": started})

@app.route("/api/logs")
def api_logs():
    return Response(sse_stream(), mimetype="text/event-stream", headers={"Cache-Control": "no-cache"})

@app.route("/api/lsblk")
def api_lsblk():
    try:
        out = subprocess.check_output(["lsblk", "-o", "NAME,PATH,SIZE,FSTYPE,MOUNTPOINT,RM,ROTA,MODEL,LABEL"], text=True)
        return jsonify({"ok": True, "lsblk": out})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500

@app.route("/api/df")
def api_df():
    try:
        out = subprocess.check_output(["df", "-hT"], text=True)
        return jsonify({"ok": True, "df": out})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500

@app.route("/api/list_destinations")
def api_list_destinations():
    found = []
    for base in DEFAULT_DOWNLOAD_DIRS:
        if os.path.isdir(base):
            for root, dirs, files in os.walk(base):
                # only list top 2 levels for speed
                depth = pathlib.Path(root).parts
                if len(depth) - len(pathlib.Path(base).parts) > 1:
                    dirs[:] = []
                    continue
                found.append(root)
    # unique + sort
    found = sorted(set(found))
    return jsonify({"paths": found})

@app.route("/api/mount", methods=["POST"])
def api_mount():
    data = request.get_json(force=True) or {}
    dev = data.get("device", "").strip()
    mnt = data.get("mountpoint", "").strip()
    if not dev or not mnt:
        return jsonify({"error": "device and mountpoint required"}), 400
    os.makedirs(mnt, exist_ok=True)
    try:
        out = subprocess.check_output(["sudo", "mount", dev, mnt], stderr=subprocess.STDOUT, text=True)
        return jsonify({"ok": True, "out": out})
    except subprocess.CalledProcessError as e:
        return jsonify({"ok": False, "out": e.output, "code": e.returncode}), 500

@app.route("/api/umount", methods=["POST"])
def api_umount():
    data = request.get_json(force=True) or {}
    target = data.get("target", "").strip()
    if not target:
        return jsonify({"error": "target required"}), 400
    try:
        out = subprocess.check_output(["sudo", "umount", target], stderr=subprocess.STDOUT, text=True)
        return jsonify({"ok": True, "out": out})
    except subprocess.CalledProcessError as e:
        return jsonify({"ok": False, "out": e.output, "code": e.returncode}), 500

# Static file fallback
@app.route("/<path:p>")
def static_passthrough(p):
    return send_from_directory(STATIC_DIR, p)

if __name__ == "__main__":
    app.run(host=HOST, port=PORT, debug=False, threaded=True)
\EOF
chmod +x /opt/ytui/app.py

cat > /opt/ytui/static/index.html <<'\EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>yt-dlp Web UI</title>
<link rel="stylesheet" href="/static/styles.css"/>
</head>
<body>
<header>
  <h1>yt-dlp Web Interface</h1>
  <div id="statusBadge" class="badge">Idle</div>
</header>

<main>
  <section class="card">
    <h2>Input</h2>
    <div class="row">
      <input id="url" type="url" placeholder="Paste video URL…" autocomplete="on"/>
      <button id="btnStart">Download</button>
      <button id="btnStop" class="secondary">Cancel</button>
    </div>
  </section>

  <details class="card" open>
    <summary>Core Options</summary>
    <div class="grid">
      <div class="field">
        <label>Destination <span class="info" title="Base folder for downloads. Defaults to a USB mount if present.">i</span></label>
        <div class="row">
          <input id="destination_dir" placeholder="/media/usb…"/>
          <button id="btnBrowsePaths" class="secondary">Suggest</button>
        </div>
        <small id="pathsHint"></small>
      </div>

      <div class="field">
        <label>Output template <span class="info" title='Example: /media/usb/%(uploader)s/%(title)s.%(ext)s'>i</span></label>
        <input id="output_template" placeholder='%(uploader)s/%(title)s.%(ext)s'/>
      </div>

      <div class="field">
        <label>Archive log <span class="info" title="Avoid re-downloading. Same file path is reused.">i</span></label>
        <input id="archive_path" placeholder="/mnt/usb/archive_log.txt"/>
      </div>
    </div>
  </details>

  <details class="card">
    <summary>Format & Quality</summary>
    <div class="row">
      <label><input type="radio" name="fmtmode" value="preset" checked> Preset</label>
      <label><input type="radio" name="fmtmode" value="custom"> Custom -f</label>
    </div>

    <div id="presetBox" class="grid">
      <div class="field">
        <label>Download type <span class="info" title="Choose audio, video, or both merged.">i</span></label>
        <select id="dl_kind">
          <option value="video_audio">Video + Audio</option>
          <option value="video">Video only</option>
          <option value="audio">Audio only</option>
        </select>
      </div>
      <div class="field">
        <label>Max height ≤ <span class="info" title="Limit resolution. Leave blank for best.">i</span></label>
        <input id="max_height" type="number" inputmode="numeric" placeholder="720"/>
      </div>
      <div class="example">
        Example produced: <code id="fmtExample">bestvideo+bestaudio/best</code>
      </div>
    </div>

    <div id="customBox" class="field" style="display:none">
      <label>-f custom <span class="info" title="Directly pass a yt-dlp format selector.">i</span></label>
      <input id="custom_format" placeholder="bestvideo*[height<=720]+bestaudio/best[height<=720]/best"/>
    </div>
  </details>

  <details class="card">
    <summary>Rate & Sleep</summary>
    <div class="grid">
      <div class="field">
        <label>--limit-rate <span class="info" title="e.g. 10000k or 2M">i</span></label>
        <input id="limit_rate" placeholder="10000k"/>
      </div>
      <div class="field">
        <label>--sleep-interval (s)</label>
        <input id="sleep_interval" type="number" inputmode="numeric" placeholder="0"/>
      </div>
      <div class="field">
        <label>--max-sleep-interval (s)</label>
        <input id="max_sleep_interval" type="number" inputmode="numeric" placeholder="0"/>
      </div>
    </div>
  </details>

  <details class="card">
    <summary>Flags</summary>
    <div class="flags">
      <!-- Error/Resumption -->
      <label><input class="flag" type="checkbox" value="--no-abort-on-error"> --no-abort-on-error</label>
      <label><input class="flag" type="checkbox" value="--skip-unavailable-fragments"> --skip-unavailable-fragments</label>
      <label><input class="flag" type="checkbox" value="--continue"> --continue</label>

      <!-- Filenames -->
      <label><input class="flag" type="checkbox" value="--restrict-filenames"> --restrict-filenames</label>
      <label><input class="flag" type="checkbox" value="--windows-filenames"> --windows-filenames</label>

      <!-- Metadata -->
      <label><input class="flag" type="checkbox" value="--embed-thumbnail"> --embed-thumbnail</label>
      <label><input class="flag" type="checkbox" value="--embed-metadata"> --embed-metadata</label>
      <label><input class="flag" type="checkbox" value="--embed-chapters"> --embed-chapters</label>
      <label><input class="flag" type="checkbox" value="--write-description"> --write-description</label>
      <label><input class="flag" type="checkbox" value="--write-info-json"> --write-info-json</label>
      <label><input class="flag" type="checkbox" value="--no-clean-info-json"> --no-clean-info-json</label>
      <label><input class="flag" type="checkbox" value="--write-subs"> --write-subs</label>

      <!-- Listing/Simulation -->
      <label><input class="flag" type="checkbox" value="--no-simulate"> --no-simulate</label>
      <label><input class="flag" type="checkbox" value="--no-ignore-no-formats-error"> --no-ignore-no-formats-error</label>
      <label><input class="flag" type="checkbox" value="--list-formats"> --list-formats</label>
      <label><input class="flag" type="checkbox" value="--list-subs"> --list-subs</label>

      <!-- Progress/Title -->
      <label><input class="flag" type="checkbox" value="--progress" checked> --progress</label>
      <label><input class="flag" type="checkbox" value="--console-title"> --console-title</label>
      <label><input class="flag" type="checkbox" value="--no-keep-fragments"> --no-keep-fragments</label>
    </div>
  </details>

  <details class="card">
    <summary>USB Tools</summary>
    <div class="row">
      <button id="btnLsblk" class="secondary">List disks</button>
      <button id="btnDf" class="secondary">Disk usage</button>
    </div>
    <pre id="blkout" class="mono"></pre>
    <div class="grid">
      <div class="field">
        <label>Mount device</label>
        <input id="mount_dev" placeholder="/dev/sda1"/>
      </div>
      <div class="field">
        <label>to</label>
        <input id="mount_point" placeholder="/media/usb1"/>
      </div>
    </div>
    <div class="row">
      <button id="btnMount">Mount</button>
      <button id="btnUmount" class="secondary">Unmount</button>
    </div>
  </details>

  <details class="card">
    <summary>Logs & Control</summary>
    <div class="row">
      <button id="btnFullscreen" class="secondary">Toggle full-screen</button>
    </div>
    <div id="progressWrap">
      <div id="progress"><span id="progressPct" style="width:0%"></span></div>
      <div id="progressText">0%</div>
    </div>
    <pre id="log" class="mono"></pre>
  </details>

  <details class="card">
    <summary>Run Custom Command</summary>
    <div class="row">
      <input id="rawCmd" placeholder="yt-dlp --help"/>
      <button id="btnRunRaw">Run</button>
    </div>
    <small>Warning: runs exactly as typed on the Pi.</small>
  </details>
</main>

<footer>
  <span>Server on Raspberry Pi. Browser is UI only.</span>
</footer>

<script src="/static/app.js"></script>
</body>
</html>
\EOF

cat > /opt/ytui/static/styles.css <<'\EOF'
:root { --bg:#0f1115; --card:#171a21; --accent:#3aa675; --text:#e7e9ee; --muted:#9aa3b2; --danger:#c74e4e; }
*{box-sizing:border-box}
html,body{margin:0;padding:0;background:var(--bg);color:var(--text);font-family:system-ui,-apple-system,Segoe UI,Roboto,Ubuntu,Cantarell,"Noto Sans",Arial,sans-serif}
header{display:flex;justify-content:space-between;align-items:center;padding:16px 20px;border-bottom:1px solid #1f2330}
h1{margin:0;font-size:20px}
main{max-width:1100px;margin:20px auto;padding:0 12px}
.card{background:var(--card);border:1px solid #232836;border-radius:14px;padding:16px;margin-bottom:14px}
.card summary{cursor:pointer;font-weight:600}
.row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px}
.field input,.field select{width:100%;padding:10px 12px;border:1px solid #2a3142;border-radius:10px;background:#10131a;color:var(--text)}
button{padding:10px 14px;border:1px solid #2e7d5b;background:var(--accent);color:#062414;border-radius:10px;cursor:pointer}
button.secondary{background:#242936;color:var(--text);border-color:#3a4154}
button:disabled{opacity:.6;cursor:not-allowed}
.info{display:inline-flex;width:18px;height:18px;align-items:center;justify-content:center;border:1px solid #3a4154;color:#9aa3b2;border-radius:50%;font-size:12px;margin-left:6px}
.example{grid-column:1/-1;padding:8px 10px;background:#111522;border:1px dashed #2c3244;border-radius:10px}
.badge{background:#2b3142;padding:6px 10px;border-radius:999px;font-size:12px}
.badge.running{background:#204a35}
.mono{background:#0c0f15;border:1px solid #22293a;border-radius:10px;padding:10px;max-height:420px;overflow:auto}
#log.full{position:fixed;inset:16px;z-index:50}
#progressWrap{display:flex;align-items:center;gap:12px;margin:10px 0}
#progress{flex:1;height:12px;background:#0c0f15;border:1px solid #22293a;border-radius:999px;overflow:hidden}
#progress span{display:block;height:100%;background:var(--accent);width:0%}
#progressText{width:60px;text-align:right;color:var(--muted)}
footer{padding:14px 20px;color:var(--muted);border-top:1px solid #1f2330}
pre{white-space:pre-wrap;word-break:break-word}
.flags{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:8px;margin-top:8px}
\EOF

cat > /opt/ytui/static/app.js <<'\EOF'
const $ = sel => document.querySelector(sel);
const $all = sel => Array.from(document.querySelectorAll(sel));

const statusBadge = $("#statusBadge");
const logEl = $("#log");
const pctEl = $("#progressPct");
const pctTxt = $("#progressText");

function setRunning(running) {
  statusBadge.textContent = running ? "Running" : "Idle";
  statusBadge.classList.toggle("running", running);
  $("#btnStart").disabled = running;
  $("#btnRunRaw").disabled = running;
  $("#btnStop").disabled = !running;
}

async function refreshStatus() {
  const r = await fetch("/api/status").then(r=>r.json());
  setRunning(r.running);
}

function appendLog(line) {
  logEl.textContent += (logEl.textContent ? "\n" : "") + line;
  logEl.scrollTop = logEl.scrollHeight;
  // Parse progress percentage
  const m = line.match(/\[download\]\s+(\d+(?:\.\d+)?)%/);
  if (m) {
    const p = parseFloat(m[1]);
    pctEl.style.width = p + "%";
    pctTxt.textContent = p.toFixed(1) + "%";
  }
}

function connectSSE() {
  const es = new EventSource("/api/logs");
  es.onmessage = e => appendLog(e.data);
  es.onerror = () => {
    es.close();
    setTimeout(connectSSE, 1500);
  };
}

function collectFlags() {
  return $all(".flag:checked").map(x => x.value);
}

function effectiveFormatExample() {
  const kind = $("#dl_kind").value;
  const h = $("#max_height").value.trim();
  if (kind === "audio") return "bestaudio/best";
  if (kind === "video") return h ? `bestvideo*[height<=${h}]` : "bestvideo";
  if (h) return `bestvideo*[height<=${h}]+bestaudio/best[height<=${h}]/best`;
  return "bestvideo+bestaudio/best";
}

function presetCustomToggle() {
  const mode = document.querySelector('input[name="fmtmode"]:checked').value;
  $("#presetBox").style.display = mode === "preset" ? "" : "none";
  $("#customBox").style.display = mode === "custom" ? "" : "none";
}

async function startDownload(raw=false) {
  logEl.textContent = "";
  pctEl.style.width = "0%";
  pctTxt.textContent = "0%";
  const url = $("#url").value.trim();
  if (!url && !raw) { alert("Enter URL"); return; }

  if (!raw) {
    const payload = {
      url,
      destination_dir: $("#destination_dir").value.trim(),
      output_template: $("#output_template").value.trim(),
      archive_path: $("#archive_path").value.trim(),
      format_mode: document.querySelector('input[name="fmtmode"]:checked').value,
      custom_format: $("#custom_format").value.trim(),
      dl_kind: $("#dl_kind").value,
      max_height: $("#max_height").value.trim(),
      limit_rate: $("#limit_rate").value.trim(),
      sleep_interval: $("#sleep_interval").value.trim(),
      max_sleep_interval: $("#max_sleep_interval").value.trim(),
      toggles: collectFlags()
    };
    const r = await fetch("/api/start", {method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify(payload)});
    const j = await r.json();
    if (!r.ok) { alert(j.error || "Failed to start"); return; }
  } else {
    const cmd = $("#rawCmd").value.trim();
    if (!cmd) { alert("Enter a command"); return; }
    const r = await fetch("/api/run_raw", {method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify({cmd})});
    const j = await r.json();
    if (!r.ok) { alert(j.error || "Failed to start"); return; }
  }
  setRunning(true);
}

async function stopDownload() {
  await fetch("/api/stop", {method:"POST"});
  // status will switch to idle when process exits; keep button enabled meanwhile
}

async function listPaths() {
  const r = await fetch("/api/list_destinations").then(r=>r.json());
  $("#pathsHint").textContent = r.paths.slice(0, 12).join("  •  ");
}

async function lsblk() {
  const j = await fetch("/api/lsblk").then(r=>r.json());
  $("#blkout").textContent = j.ok ? j.lsblk : j.error;
}
async function df() {
  const j = await fetch("/api/df").then(r=>r.json());
  $("#blkout").textContent = j.ok ? j.df : j.error;
}
async function mount() {
  const dev = $("#mount_dev").value.trim();
  const mnt = $("#mount_point").value.trim();
  if (!dev || !mnt) { alert("device and mountpoint required"); return; }
  const r = await fetch("/api/mount", {method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify({device:dev, mountpoint:mnt})}).then(r=>r.json());
  $("#blkout").textContent = (r.ok ? r.out : (r.out||r.error||"error"));
}
async function umount() {
  const target = $("#mount_point").value.trim() || $("#mount_dev").value.trim();
  if (!target) { alert("target required"); return; }
  const r = await fetch("/api/umount", {method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify({target})}).then(r=>r.json());
  $("#blkout").textContent = (r.ok ? r.out : (r.out||r.error||"error"));
}

function bind() {
  $("#btnStart").onclick = () => startDownload(false);
  $("#btnRunRaw").onclick = () => startDownload(true);
  $("#btnStop").onclick = stopDownload;
  $("#btnBrowsePaths").onclick = listPaths;
  $("#btnLsblk").onclick = lsblk;
  $("#btnDf").onclick = df;
  $("#btnMount").onclick = mount;
  $("#btnUmount").onclick = umount;
  $("#btnFullscreen").onclick = () => logEl.classList.toggle("full");
  $all('input[name="fmtmode"]').forEach(r=>r.onchange = presetCustomToggle);
  $("#dl_kind").onchange = () => $("#fmtExample").textContent = effectiveFormatExample();
  $("#max_height").oninput = () => $("#fmtExample").textContent = effectiveFormatExample();
}

window.addEventListener("load", async () => {
  bind();
  presetCustomToggle();
  $("#fmtExample").textContent = effectiveFormatExample();
  connectSSE();
  refreshStatus();
  // Attempt to guess a USB mount
  const r = await fetch("/api/list_destinations").then(r=>r.json());
  const usb = r.paths.find(p => /\/media\/|\/mnt\//.test(p)) || "";
  if (usb && !$("#destination_dir").value) $("#destination_dir").value = usb;
});
\EOF

cat > /opt/ytui/README.md <<'\EOF'
# yt-dlp Web UI for Raspberry Pi

Local network web interface. Backend runs on the Pi. Browser is UI only.

## 1) Install on Raspberry Pi

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip yt-dlp \
  lsblk util-linux coreutils
# optional codecs and ffmpeg for muxing:
sudo apt install -y ffmpeg