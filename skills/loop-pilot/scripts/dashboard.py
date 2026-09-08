#!/usr/bin/env python3
"""loop-pilot dashboard — one browser tab that shows every loop, live.

Usage:
    dashboard.py                 serve on http://localhost:8787 (repos from ~/.loop-pilot/repos.txt)
    dashboard.py --port 9000
    dashboard.py /path/repo1 /path/repo2

Answers the question status.sh answers, continuously, for every feature at once —
plus the one signal a quiet log can't give you: WHICH FILES THE AGENT IS ACTUALLY
WRITING right now. `claude -p` prints nothing until a phase ends, so the log is
silent mid-phase by design; file mtimes in the repo are the true heartbeat.
"""
import json, os, re, subprocess, sys, time
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

POLL_MS = 5000
# Finished runs age out of the view. A loop that completed weeks ago is history, not status;
# leaving it on the board makes the board something you scroll instead of something you read.
HIDE_DONE_AFTER_DAYS = float(os.environ.get("DASH_HIDE_DONE_AFTER_DAYS", "5"))
HIDE_DONE_AFTER_S = HIDE_DONE_AFTER_DAYS * 86400
ACTIVE_WINDOW_S = 180        # a file written in the last 3 min = agent is typing
STALL_S = 1800               # alive but nothing written & log frozen 30 min = wedged
SKIP_DIRS = {".git", "node_modules", ".next", "dist", "build", ".expo", ".patches"}

def repo_roots(argv):
    roots = [a for a in argv if not a.startswith("-")]
    if not roots:
        cfg = Path.home() / ".loop-pilot" / "repos.txt"
        if cfg.exists():
            roots = [l.strip() for l in cfg.read_text().splitlines()
                     if l.strip() and not l.startswith("#")]
    return [Path(r) for r in roots if Path(r).is_dir()]

def find_features(roots):
    feats = []
    for root in roots:
        for st in root.glob("**/docs/features/*/status.md"):
            if any(p in SKIP_DIRS for p in st.parts):
                continue
            feats.append(st.parent)
    return sorted(set(feats))

def state_dir():
    return Path(os.environ.get("LOOP_PILOT_STATE", str(Path.home() / ".loop-pilot")))

def runinfo(fdir):
    """The runner's own record of the last run: agent, result, counts, timestamps."""
    d = {}
    try:
        for line in (fdir / ".runinfo").read_text(errors="replace").splitlines():
            if "=" in line:
                k, v = line.split("=", 1); d[k] = v
    except OSError:
        pass
    return d

QA_LINE = re.compile(r"^(\s*)- \[( |x|X)\] (.*)$")

def qa_items(fdir):
    """QA.md as structured items, so the board can show and tick the owner's test list."""
    out, section = [], ""
    try:
        lines = (fdir / "QA.md").read_text(errors="replace").splitlines()
    except OSError:
        return out
    for i, line in enumerate(lines):
        if line.startswith("## "):
            section = line[3:].strip()
            continue
        m = QA_LINE.match(line)
        if m:
            out.append({"line": i, "indent": len(m.group(1)), "done": m.group(2).lower() == "x",
                        "text": m.group(3), "section": section})
    return out

def qa_toggle(fdir, line_no, done):
    """Tick or untick one QA.md checkbox in place, leaving every other byte alone."""
    path = Path(fdir) / "QA.md"
    lines = path.read_text(errors="replace").splitlines(keepends=True)
    if not (0 <= line_no < len(lines)):
        return False
    m = QA_LINE.match(lines[line_no].rstrip("\n"))
    if not m:
        return False
    ending = "\n" if lines[line_no].endswith("\n") else ""
    lines[line_no] = f"{m.group(1)}- [{'x' if done else ' '}] {m.group(3)}{ending}"
    path.write_text("".join(lines))
    return True

def pid_alive(pid):
    try:
        os.kill(int(pid), 0); return True
    except Exception:
        return False

def phase_rows(status_path):
    rows = []
    try:
        for line in status_path.read_text(errors="replace").splitlines():
            m = re.match(r"^\|\s*(P[0-9][^\s|]*)\s*\|\s*([^|]*)\|(.*)$", line)
            if m:
                rest = [c.strip() for c in m.group(3).split("|")]
                rows.append({"phase": m.group(1), "state": m.group(2).strip(),
                             "deps": rest[0] if rest else "",
                             "notes": rest[1] if len(rest) > 1 else ""})
    except OSError:
        pass
    return rows

def recent_writes(repo, feature_dir, window_s):
    """Files modified in the repo within window_s — the agent's heartbeat."""
    now, out = time.time(), []
    try:
        for dirpath, dirnames, filenames in os.walk(repo):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for fn in filenames:
                p = Path(dirpath) / fn
                try:
                    age = now - p.stat().st_mtime
                except OSError:
                    continue
                if age <= window_s:
                    rel = str(p.relative_to(repo))
                    kind = "meta" if str(feature_dir) in str(p) else "code"
                    out.append({"file": rel, "age_s": int(age), "kind": kind})
    except OSError:
        pass
    out.sort(key=lambda x: x["age_s"])
    return out[:20]

def tail(path, n=10):
    try:
        return path.read_text(errors="replace").splitlines()[-n:]
    except OSError:
        return []

def feature_report(fdir):
    repo = fdir.parents[2]
    logs = sorted(fdir.glob("loop-run-*.log"), key=lambda p: p.stat().st_mtime, reverse=True)
    log = logs[0] if logs else None
    pidf = fdir / "loop.pid"
    pid = pidf.read_text().strip() if pidf.exists() else ""
    alive = bool(pid) and pid_alive(pid)
    rows = phase_rows(fdir / "status.md")
    done = sum(1 for r in rows if r["state"] == "done")
    inflight = [r["phase"] for r in rows if r["state"] == "in-progress"]
    # the runner publishes the phases it actually has in flight; prefer it when present
    try:
        pub = (fdir / ".run" / "inflight").read_text().split()
        if pub:
            inflight = pub
    except Exception:
        pass
    cur = ", ".join(inflight)
    now = time.time()
    log_age = int(now - log.stat().st_mtime) if log else None
    writes = recent_writes(repo, fdir, ACTIVE_WINDOW_S) if alive else []
    code_writes = [w for w in writes if w["kind"] == "code"]

    audits = sorted(fdir.glob("audit-*.md"), key=lambda p: p.stat().st_mtime, reverse=True)
    info = runinfo(fdir)
    qa = qa_items(fdir)
    qa_open = sum(1 for q in qa if not q["done"])
    if not alive and info.get("pid") and pid_alive(info["pid"]):
        alive, pid = True, info["pid"]

    if alive:
        if code_writes:
            verdict, cls = f"RUNNING · writing code ({code_writes[0]['file']})", "ok"
        elif log_age is not None and log_age > STALL_S:
            verdict, cls = f"RUNNING · possibly wedged — no writes, log frozen {log_age//60}m", "warn"
        else:
            verdict, cls = "RUNNING · agent thinking (no file writes yet this window)", "think"
    else:
        result = info.get("result", "")
        if result == "COMPLETE":
            verdict, cls = (f"STOPPED · COMPLETE — {qa_open} QA item(s) for you", "done") if qa_open \
                else ("STOPPED · COMPLETE — QA list all ticked", "done")
        elif result == "INCOMPLETE":
            verdict, cls = f"STOPPED · INCOMPLETE — {info.get('defects','?')} defect(s), {qa_open} QA item(s)", "hand"
        elif info:
            verdict, cls = "STOPPED · EXITED mid-run — no ending written, relaunch to resume", "err"
        elif log:
            verdict, cls = "STOPPED · EXITED — read the log tail", "err"
        else:
            verdict, cls = "NEVER LAUNCHED", "idle"

    # "finished" = nothing in flight and every phase done. Age = the most recent trace of
    # this run: status.md, the run log, QA.md, or the audit — whichever moved last.
    finished = (not alive) and (bool(info.get("result")) or (len(rows) > 0 and done == len(rows)))
    stamps = []
    for p in (fdir / "status.md", log, fdir / "QA.md", audits[0] if audits else None):
        try:
            if p is not None and p.exists():
                stamps.append(p.stat().st_mtime)
        except OSError:
            pass
    last_activity = max(stamps) if stamps else 0
    age_days = (now - last_activity) / 86400 if last_activity else None

    return {
        "feature": fdir.name, "dir": str(fdir), "repo": str(repo),
        "finished": finished, "age_days": round(age_days, 1) if age_days is not None else None,
        "verdict": verdict, "cls": cls, "alive": alive, "pid": pid,
        "done": done, "total": len(rows), "current": cur, "phases": rows,
        "log": str(log) if log else "", "log_age_s": log_age,
        "log_tail": tail(log) if log else [],
        "writes": writes,
        "audit": str(audits[0]) if audits else "",
        "result": info.get("result", ""), "agent": info.get("agent", ""),
        "qa": qa, "qa_open": qa_open, "qa_file": str(fdir / "QA.md") if (fdir / "QA.md").exists() else "",
    }

PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>loop-pilot</title>
<style>
 body{background:#0d1117;color:#c9d1d9;font:14px/1.5 ui-monospace,Menlo,monospace;margin:0;padding:24px}
 h1{font-size:16px;color:#8b949e;font-weight:600} h1 b{color:#e6edf3}
 .card{background:#161b22;border:1px solid #30363d;border-radius:10px;padding:16px 18px;margin:14px 0}
 .v{font-weight:700;font-size:15px} .ok .v{color:#3fb950}.think .v{color:#d29922}
 .warn .v{color:#f85149}.done .v{color:#58a6ff}.hand .v{color:#bc8cff}.err .v{color:#f85149}.idle .v{color:#8b949e}
 .bar{height:6px;background:#21262d;border-radius:3px;margin:8px 0}
 .bar i{display:block;height:6px;border-radius:3px;background:#238636}
 table{border-collapse:collapse;margin:8px 0;width:100%} td,th{padding:2px 10px 2px 0;text-align:left;color:#8b949e}
 td.s-done{color:#3fb950} td.s-in-progress{color:#d29922} td.s-blocked,td.s-qa-pending{color:#f85149} td.s-todo{color:#8b949e}
 .writes span{display:inline-block;background:#1f2937;border-radius:5px;padding:1px 8px;margin:2px 4px 2px 0;color:#7ee787}
 .writes span.meta{color:#8b949e}
 pre{background:#0d1117;border:1px solid #21262d;border-radius:6px;padding:8px 10px;color:#8b949e;overflow-x:auto;font-size:12px}
 .dim{color:#484f58;font-size:12px} .hb{color:#7ee787}
 .qa{margin:10px 0;border-top:1px solid #21262d;padding-top:8px}
 .qa h3{font-size:12px;color:#8b949e;margin:8px 0 4px;text-transform:uppercase;letter-spacing:.04em}
 .qa label{display:block;padding:1px 0;color:#c9d1d9;cursor:pointer}
 .qa label.sub{padding-left:20px;color:#8b949e}
 .qa label.ticked{color:#484f58;text-decoration:line-through}
 .qa input{accent-color:#238636;margin-right:8px}
</style></head><body>
<h1>loop-pilot <b>live</b> <span class=dim id=ts></span></h1><div id=app>loading…</div>
<script>
const esc = s => String(s).replace(/[&<>"']/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
async function tick(dir, line, done){
  await fetch('/qa', {method:'POST', headers:{'Content-Type':'application/json'},
                      body: JSON.stringify({dir, line, done})});
}
async function poll(){
 try{
  const r = await fetch('/api' + location.search); const d = await r.json();
  document.getElementById('ts').textContent = ' · refreshed ' + new Date().toLocaleTimeString();
  const pb = d.paused_until ? `<div class=card style="border-color:#d29922"><div class=v style="color:#d29922">⏸ FLEET PAUSED — rate-limit brake. Loops finish their current phase, then wait. Resumes ${new Date(d.paused_until*1000).toLocaleTimeString()}</div></div>` : '';
  document.getElementById('app').innerHTML = pb + d.features.map(f=>{
   const pct = f.total ? Math.round(100*f.done/f.total) : 0;
   const ph = f.phases.map(p=>`<tr><td>${esc(p.phase)}</td><td class="s-${esc(p.state)}">${esc(p.state)}</td><td>${esc(p.deps)}</td><td>${esc(p.notes)}</td></tr>`).join('');
   const wr = f.writes.length
     ? '<div class=writes>heartbeat: ' + f.writes.map(w=>`<span class="${w.kind}">${esc(w.file)} <i class=dim>${w.age_s}s</i></span>`).join('') + '</div>'
     : (f.alive ? '<div class=dim>no files written in the last 3 min — agent is reading/thinking, or check again shortly</div>' : '');
   const lg = f.log_tail.length ? `<pre>${esc(f.log_tail.join('\\n'))}</pre>` : '';
   let qa = '';
   if (f.qa && f.qa.length) {
     let sec = '';
     qa = '<div class=qa>' + f.qa.map(q => {
       let h = '';
       if (q.section !== sec) { sec = q.section; h = `<h3>${esc(sec)}</h3>`; }
       return h + `<label class="${q.indent? 'sub':''} ${q.done? 'ticked':''}">`
         + `<input type=checkbox ${q.done?'checked':''} onchange="tick('${esc(f.dir)}',${q.line},this.checked)">`
         + esc(q.text) + '</label>';
     }).join('') + `<div class=dim>${esc(f.qa_file)}</div></div>`;
   }
   return `<div class="card ${f.cls}">
     <div class=v>${esc(f.feature)} — ${esc(f.verdict)}</div>
     <div class=dim>${f.done}/${f.total} phases${f.current? (f.current.includes(',')? ' · in flight: ':' · now: ')+esc(f.current):''}${f.alive? ' · pid '+f.pid:''}${f.log_age_s!=null? ' · log moved '+f.log_age_s+'s ago':''}${(!f.alive && f.finished && f.age_days!=null)? ' · finished '+f.age_days+'d ago':''}</div>
     <div class=bar><i style="width:${pct}%"></i></div>
     <table>${ph}</table>${qa}${wr}${lg}
     <div class=dim>${esc(f.dir)}</div></div>`;
  }).join('') || '<div class=card>no features found</div>';
  const foot = d.showing_all
    ? `<div class=dim style="margin-top:14px">showing every run, finished ones included · <a href="/" style="color:#58a6ff">back to active</a></div>`
    : (d.hidden.length
        ? `<div class=dim style="margin-top:14px">${d.hidden.length} finished run(s) older than ${d.hide_after_days}d hidden: ${d.hidden.map(esc).join(', ')} · <a href="/?all=1" style="color:#58a6ff">show all</a></div>`
        : `<div class=dim style="margin-top:14px">finished runs drop off this board after ${d.hide_after_days} days · <a href="/?all=1" style="color:#58a6ff">show all</a></div>`);
  document.getElementById('app').insertAdjacentHTML('beforeend', foot);
 }catch(e){ document.getElementById('ts').textContent=' · reconnecting…'; }
 setTimeout(poll, %POLL%);
}
poll();
</script></body></html>"""

class H(BaseHTTPRequestHandler):
    roots = []
    def log_message(self, *a): pass
    def _send(self, body, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body.encode())
    def do_POST(self):
        if not self.path.startswith("/qa"):
            self.send_response(404); self.end_headers(); return
        try:
            n = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(n) or b"{}")
            fdir = Path(req["dir"]).resolve()
            # only ever touch a QA.md inside one of the roots this dashboard was told to watch
            if not any(str(fdir).startswith(str(Path(r).resolve())) for r in self.roots):
                raise ValueError("feature dir outside the watched roots")
            ok = qa_toggle(fdir, int(req["line"]), bool(req["done"]))
            self._send(json.dumps({"ok": ok}), "application/json")
        except Exception as e:
            self.send_response(400); self.send_header("Content-Type", "application/json")
            self.end_headers(); self.wfile.write(json.dumps({"error": str(e)}).encode())

    def do_GET(self):
        if self.path.startswith("/api"):
            show_all = "all=1" in (self.path.split("?", 1)[1] if "?" in self.path else "")
            feats = [feature_report(f) for f in find_features(self.roots)]
            hidden = []
            if not show_all and HIDE_DONE_AFTER_S > 0:
                keep = []
                for f in feats:
                    if f["finished"] and f["age_days"] is not None and f["age_days"] * 86400 > HIDE_DONE_AFTER_S:
                        hidden.append(f["feature"])
                    else:
                        keep.append(f)
                feats = keep
            feats.sort(key=lambda f: (not f["alive"], f["feature"]))
            paused_until = None
            pf = state_dir() / "pause"
            if pf.exists():
                try:
                    t = int(pf.read_text().strip())
                    if t > time.time():
                        paused_until = t
                except ValueError:
                    pass
            self._send(json.dumps({
                "features": feats, "paused_until": paused_until,
                "hidden": hidden, "hide_after_days": HIDE_DONE_AFTER_DAYS,
                "showing_all": show_all,
            }), "application/json")
        else:
            self._send(PAGE.replace("%POLL%", str(POLL_MS)), "text/html")

def main():
    argv = sys.argv[1:]
    port = 8787
    if "--port" in argv:
        i = argv.index("--port"); port = int(argv[i+1]); argv = argv[:i] + argv[i+2:]
    roots = repo_roots(argv)
    if not roots:
        sys.exit("No repo roots: pass paths or create ~/.loop-pilot/repos.txt")
    H.roots = roots
    print(f"loop-pilot dashboard → http://localhost:{port}  (watching: {', '.join(map(str, roots))})")
    print("Ctrl-C stops the dashboard only — loops keep flying.")
    HTTPServer(("127.0.0.1", port), H).serve_forever()

if __name__ == "__main__":
    main()
