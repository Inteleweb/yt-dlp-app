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
        current_proc.update({"p": p, "start_ts": time.time(), "args": args, "raw": raw})
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