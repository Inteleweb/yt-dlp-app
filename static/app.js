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
      output_filename: $("#output_filename").value.trim(),
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