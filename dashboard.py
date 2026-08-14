#!/usr/bin/env python3
"""Claude Déjà Vu — a dashboard for your Claude Code conversations.

Scans ~/.claude/projects/**/*.jsonl for sessions active in the last 4 weeks and
serves a local web view: browse recent sessions (newest first, grouped by
project), full-text keyword search with a 48h/7d/all time scope, and an
on-demand "Analyze" action that uses the local `claude` CLI to summarize each
session and cluster correlated sessions across projects (cached to insights.json).

Stdlib only. The only external call is shelling out to `claude` for Analyze.

Run:      python3 dashboard.py         (then open http://127.0.0.1:8765)
Selftest: python3 dashboard.py --selftest
"""

import glob
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HOME = os.path.expanduser("~")
# Env overrides exist so you can point the viewer at a copy of the logs (or demo data).
PROJECTS_DIR = os.environ.get("DEJAVU_PROJECTS_DIR") or os.path.join(HOME, ".claude", "projects")
INSIGHTS_FILE = os.environ.get("DEJAVU_INSIGHTS") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "insights.json")
PORT = 8765
WEEKS = 4
WINDOW_SECONDS = WEEKS * 7 * 24 * 3600
SAMPLE_CHARS = 700  # chars sent to Claude per session (start+middle+end)
MAX_ANALYZE_SESSIONS = 40  # cap the batch so the prompt stays small enough to parse

SCOPES = {"48h": 48 * 3600, "7d": 7 * 24 * 3600, "all": WINDOW_SECONDS}


# --- parsing -----------------------------------------------------------------

def _text_of(content):
    """Plain text from a message .content (string, or list of blocks)."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for b in content:
            if isinstance(b, dict) and isinstance(b.get("text"), str):
                parts.append(b["text"])
        return " ".join(parts)
    return ""


def _epoch(ts):
    """ISO-8601 (e.g. 2026-08-13T19:24:15.365Z) -> epoch seconds, or None."""
    if not isinstance(ts, str):
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _is_real_user_text(text, is_meta):
    """A user message usable as a fallback title: real prose, not machinery."""
    if is_meta or not text:
        return False
    t = text.strip()
    if not t or t.startswith("<"):
        return False
    if t.startswith("Another Claude session sent a message"):  # cross-session
        return False
    return True


def parse_session(path):
    """Parse one .jsonl session file into a summary dict (or None if empty)."""
    custom_title = None
    fallback_title = None
    cwd = None
    branch = None
    first_ts = None
    last_ts = None
    msg_count = 0
    blob_parts = []

    try:
        f = open(path, "r", encoding="utf-8", errors="replace")
    except OSError:
        return None
    with f:
        for line in f:
            try:
                o = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue  # skip malformed line, keep going
            t = o.get("type")
            if t == "custom-title":
                custom_title = o.get("customTitle") or custom_title
                continue
            if t not in ("user", "assistant"):
                continue
            msg = o.get("message", {}) or {}
            text = _text_of(msg.get("content"))
            if text:
                blob_parts.append(text)
            if o.get("cwd"):
                cwd = o["cwd"]
            if o.get("gitBranch"):
                branch = o["gitBranch"]
            ep = _epoch(o.get("timestamp"))
            if ep is not None:
                first_ts = ep if first_ts is None else min(first_ts, ep)
                last_ts = ep if last_ts is None else max(last_ts, ep)
            msg_count += 1
            if (t == "user" and fallback_title is None
                    and _is_real_user_text(text, o.get("isMeta"))):
                fallback_title = text.strip()

    if msg_count == 0 or last_ts is None:
        return None

    title = custom_title or fallback_title or "(untitled session)"
    return {
        "id": os.path.splitext(os.path.basename(path))[0],
        "path": path,
        "title": title[:200],
        "project": cwd or "(unknown)",
        "branch": branch,
        "first": first_ts,
        "last": last_ts,
        "count": msg_count,
        "blob": "\n".join(blob_parts),
    }


def scan_all():
    """Parsed sessions active within the last 4 weeks, newest activity first."""
    if not os.path.isdir(PROJECTS_DIR):
        return []
    cutoff = time.time() - WINDOW_SECONDS
    sessions = []
    for path in glob.glob(os.path.join(PROJECTS_DIR, "**", "*.jsonl"), recursive=True):
        try:
            if os.path.getmtime(path) < cutoff:
                continue  # cheap pre-filter: skip old files without parsing
        except OSError:
            continue
        s = parse_session(path)
        if s and s["last"] >= cutoff:
            sessions.append(s)
    sessions.sort(key=lambda s: s["last"], reverse=True)
    return sessions


# --- AI insights -------------------------------------------------------------

def sample_text(blob, limit=SAMPLE_CHARS):
    """~limit chars drawn from start+middle+end so buried topics still show."""
    if len(blob) <= limit:
        return blob
    n = limit // 3
    mid = len(blob) // 2
    start = blob[:n]
    middle = blob[mid - n // 2: mid + n // 2]
    end = blob[-n:]
    return f"{start}\n…\n{middle}\n…\n{end}"


def build_analyze_prompt(sessions):
    digests = [{
        "id": s["id"],
        "title": s["title"],
        "project": s["project"],
        "sample": sample_text(s["blob"]),
    } for s in sessions]
    return (
        "You analyze a developer's Claude Code sessions to help them recall and "
        "find conversations. For the sessions below, return ONLY a JSON object "
        "(no prose, no markdown fences) of the form:\n"
        '{"summaries": {"<session_id>": "one concise line of what it was about"}, '
        '"clusters": [{"label": "short topic name", "session_ids": ["id", ...]}]}\n'
        "Clusters are topics that may span different projects; group sessions that "
        "discuss related work even across projects. A session may be in no cluster. "
        "Use only the given session ids.\n\nSESSIONS:\n"
        + json.dumps(digests, ensure_ascii=False)
    )


def _extract_json(text):
    """Pull the first {...} JSON object out of possibly-noisy CLI output."""
    text = text.replace("```json", "").replace("```", "")  # tolerate code fences
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end < start:
        raise ValueError("no JSON object in output")
    return json.loads(text[start:end + 1])


def run_analysis(sessions):
    """Call the local `claude` CLI once; write insights.json. Returns result dict."""
    # A 150-session prompt (~260KB) overflows the CLI; cap to the most recent.
    prompt = build_analyze_prompt(sessions[:MAX_ANALYZE_SESSIONS])
    try:
        proc = subprocess.run(
            ["claude", "-p"], input=prompt,
            capture_output=True, text=True, timeout=300,
        )
    except FileNotFoundError:
        return {"ok": False, "error": "The `claude` CLI was not found on PATH."}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "Analysis timed out."}
    if proc.returncode != 0:
        return {"ok": False, "error": (proc.stderr or "claude CLI failed").strip()[:300]}
    try:
        data = _extract_json(proc.stdout)
        summaries = data.get("summaries", {}) or {}
        clusters = data.get("clusters", []) or []
        assert isinstance(summaries, dict) and isinstance(clusters, list)
    except (ValueError, AssertionError, json.JSONDecodeError):
        return {"ok": False, "error": "Claude returned output that could not be parsed."}
    insights = {"summaries": summaries, "clusters": clusters, "generated": time.time()}
    try:
        with open(INSIGHTS_FILE, "w", encoding="utf-8") as fh:
            json.dump(insights, fh)
    except OSError:
        pass  # analysis still usable this run even if the cache write fails
    return {"ok": True, "insights": insights}


def load_insights():
    try:
        with open(INSIGHTS_FILE, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None


def merge_insights(sessions, insights):
    """Attach summary + cluster labels to each session; tolerate missing/extra ids."""
    if not insights:
        return
    summaries = insights.get("summaries", {})
    clusters = insights.get("clusters", [])
    labels_by_id = {}
    for c in clusters:
        label = c.get("label")
        for sid in c.get("session_ids", []):
            labels_by_id.setdefault(sid, []).append(label)
    for s in sessions:
        s["summary"] = summaries.get(s["id"])
        s["clusters"] = labels_by_id.get(s["id"], [])


# --- single transcript -------------------------------------------------------

ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")  # session-id / filename stem


def read_transcript(session_id):
    """Full ordered messages for one session, or None if the id is unknown."""
    if not session_id or not ID_RE.match(session_id):
        return None  # reject anything that could escape PROJECTS_DIR
    matches = glob.glob(os.path.join(PROJECTS_DIR, "**", session_id + ".jsonl"),
                        recursive=True)
    if not matches:
        return None
    custom_title = None
    fallback_title = None
    project = None
    messages = []
    with open(matches[0], "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                o = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            t = o.get("type")
            if t == "custom-title":
                custom_title = o.get("customTitle") or custom_title
                continue
            if t not in ("user", "assistant"):
                continue
            msg = o.get("message", {}) or {}
            text = _text_of(msg.get("content"))
            if not text:
                continue
            if o.get("cwd"):
                project = o["cwd"]
            role = msg.get("role") or t
            if (role == "user" and fallback_title is None
                    and _is_real_user_text(text, o.get("isMeta"))):
                fallback_title = text.strip()
            messages.append({"role": role, "text": text, "ts": _epoch(o.get("timestamp"))})
    return {
        "title": (custom_title or fallback_title or "(untitled session)")[:200],
        "project": project or "(unknown)",
        "messages": messages,
    }


# --- serialization for the API ----------------------------------------------

def _snippet(blob, term, width=160):
    low = blob.lower()
    i = low.find(term.lower())
    if i == -1:
        return None
    start = max(0, i - width // 2)
    end = min(len(blob), i + len(term) + width // 2)
    pre = "…" if start > 0 else ""
    post = "…" if end < len(blob) else ""
    return pre + blob[start:end].replace("\n", " ").strip() + post


def session_view(s, term=None):
    v = {
        "id": s["id"], "title": s["title"], "project": s["project"],
        "branch": s.get("branch"), "last": s["last"], "count": s["count"],
        "summary": s.get("summary"), "clusters": s.get("clusters", []),
        "snippet": _snippet(s["blob"], term) if term else None,
    }
    return v


def api_sessions(q, scope):
    sessions = scan_all()
    merge_insights(sessions, load_insights())
    window = SCOPES.get(scope, WINDOW_SECONDS)
    cutoff = time.time() - window
    sessions = [s for s in sessions if s["last"] >= cutoff]
    if q:
        ql = q.lower()
        sessions = [s for s in sessions if ql in s["blob"].lower()]
    clusters = sorted({c for s in sessions for c in s.get("clusters", []) if c})
    return {
        "sessions": [session_view(s, q or None) for s in sessions],
        "clusters": clusters,
        "analyzed": bool(load_insights()),
    }


# --- HTTP --------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/":
            self._send(200, PAGE, "text/html; charset=utf-8")
        elif u.path == "/api/sessions":
            qs = parse_qs(u.query)
            q = (qs.get("q", [""])[0]).strip()
            scope = qs.get("scope", ["all"])[0]
            self._send(200, json.dumps(api_sessions(q, scope)))
        elif u.path == "/api/session":
            sid = parse_qs(u.query).get("id", [""])[0]
            data = read_transcript(sid)
            if data is None:
                self._send(404, json.dumps({"error": "session not found"}))
            else:
                self._send(200, json.dumps(data))
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        u = urlparse(self.path)
        if u.path == "/api/analyze":
            result = run_analysis(scan_all())
            if result["ok"]:
                self._send(200, json.dumps({"ok": True}))
            else:
                self._send(200, json.dumps({"ok": False, "error": result["error"]}))
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def log_message(self, *args):
        pass  # quiet


PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Claude Déjà Vu</title>
<style>
:root{
  --mono:ui-monospace,'SF Mono',Menlo,Consolas,monospace;
  --sans:-apple-system,system-ui,'Segoe UI',sans-serif;
  --bg:#f2f1ee; --pane:#fbfaf8; --ink:#1e1d1b; --faded:#78746c; --line:#dedbd4;
  --sel:#eceae4; --accent:#a6382a; --accent-soft:rgba(166,56,42,.13);
  color-scheme:light dark;
}
@media(prefers-color-scheme:dark){:root{
  --bg:#131315; --pane:#191a1d; --ink:#e6e4df; --faded:#8b8781; --line:#2a2b2f;
  --sel:#232529; --accent:#e0705a; --accent-soft:rgba(224,112,90,.18);
}}
*{box-sizing:border-box}
html,body{height:100%}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.55 var(--sans);
  display:flex;flex-direction:column;overflow:hidden;-webkit-font-smoothing:antialiased}
:focus-visible{outline:2px solid var(--accent);outline-offset:-2px}

/* ---- top bar ---- */
header{display:flex;align-items:center;gap:18px;flex-wrap:wrap;
  padding:11px 18px;background:var(--pane);border-bottom:1px solid var(--line)}
.mark{font:700 15px/1 var(--sans);letter-spacing:-.01em;white-space:nowrap}
.mark span{color:var(--accent)}
#q{flex:1;min-width:200px;font:14px/1 var(--sans);color:var(--ink);background:var(--bg);
  border:1px solid var(--line);border-radius:6px;padding:8px 11px}
#q::placeholder{color:var(--faded)}
#q:focus{outline:0;border-color:var(--accent)}
.scope{display:inline-flex;background:var(--bg);border:1px solid var(--line);
  border-radius:6px;padding:2px}
.scope button{font:600 11px/1 var(--mono);letter-spacing:.06em;text-transform:uppercase;
  background:0;border:0;color:var(--faded);cursor:pointer;padding:6px 10px;border-radius:4px}
.scope button.on{background:var(--accent);color:#fff}
#analyze{font:600 11px/1 var(--mono);letter-spacing:.08em;text-transform:uppercase;
  background:0;color:var(--accent);cursor:pointer;padding:7px 11px;
  border:1px solid var(--accent);border-radius:6px;white-space:nowrap}
#analyze:hover{background:var(--accent);color:#fff}
#msg{font:400 12px/1.4 var(--mono);color:var(--faded)}

/* ---- cluster bar ---- */
#chips{display:flex;gap:8px;flex-wrap:wrap;align-items:center;padding:12px 18px;
  background:var(--bg);border-bottom:1px solid var(--line);
  box-shadow:inset 3px 0 0 var(--accent)}
#chips:empty{display:none}
#chips .lbl{font:700 11px/1 var(--mono);letter-spacing:.13em;text-transform:uppercase;
  color:var(--accent);margin-right:6px}
#chips .hint-inline{font:400 12.5px/1 var(--sans);color:var(--faded)}
.chip{display:inline-flex;align-items:center;gap:8px;font:500 13px/1 var(--sans);
  background:var(--pane);color:var(--ink);cursor:pointer;
  border:1px solid var(--line);border-radius:14px;padding:7px 13px}
.chip:hover{border-color:var(--accent);color:var(--accent)}
.chip .n{font:600 11px/1 var(--mono);color:var(--faded);
  background:var(--sel);border-radius:8px;padding:3px 6px}
.chip.on{background:var(--accent);color:#fff;border-color:var(--accent)}
.chip.on .n{background:rgba(255,255,255,.22);color:#fff}

/* ---- two panes ---- */
.panes{flex:1;display:flex;min-height:0}
.left{width:390px;flex:none;display:flex;flex-direction:column;
  border-right:1px solid var(--line);background:var(--pane);min-height:0}
.count{font:400 11px/1 var(--mono);letter-spacing:.14em;text-transform:uppercase;
  color:var(--faded);padding:11px 18px;border-bottom:1px solid var(--line)}
#list{overflow-y:auto;flex:1}
.row{padding:13px 18px;border-bottom:1px solid var(--line);cursor:pointer;
  border-left:3px solid transparent}
.row:hover{background:var(--sel)}
.row.on{background:var(--sel);border-left-color:var(--accent)}
.rtop{display:flex;justify-content:space-between;align-items:baseline;gap:10px}
.eyebrow{font:400 10px/1.3 var(--mono);letter-spacing:.09em;text-transform:uppercase;
  color:var(--faded);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.when{font:400 10px/1.3 var(--mono);color:var(--faded);white-space:nowrap}
.row.recent .when{color:var(--accent);font-weight:700}
.title{font:600 14px/1.4 var(--sans);margin:5px 0 0;
  display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.summary{font:400 12.5px/1.5 var(--sans);color:var(--faded);margin-top:4px;
  display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.snippet{font:400 12px/1.5 var(--sans);color:var(--faded);margin-top:7px;
  padding-left:9px;border-left:2px solid var(--accent-soft);
  display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.tags{margin-top:7px;display:flex;gap:10px;flex-wrap:wrap}
.tag{font:400 11px/1 var(--mono);color:var(--accent)}
.tag::before{content:'\\2248 '}
mark{background:var(--accent-soft);color:var(--accent);font-weight:700;padding:0 2px;
  border-radius:2px}

/* ---- right pane ---- */
.right{flex:1;display:flex;flex-direction:column;min-width:0;min-height:0}
.dtop{padding:14px 26px;border-bottom:1px solid var(--line);background:var(--pane);
  display:flex;align-items:flex-start;justify-content:space-between;gap:18px}
.dtop-text{min-width:0}
.dtop h2{font:600 17px/1.35 var(--sans);margin:4px 0 0;max-width:900px;
  display:-webkit-box;-webkit-line-clamp:1;-webkit-box-orient:vertical;overflow:hidden}
#d-close{flex:none;font:600 10px/1 var(--mono);letter-spacing:.1em;text-transform:uppercase;
  background:0;color:var(--faded);cursor:pointer;padding:7px 10px;white-space:nowrap;
  border:1px solid var(--line);border-radius:6px}
#d-close:hover{color:var(--accent);border-color:var(--accent)}
#thread{overflow-y:auto;flex:1;padding:0 26px 40px}
.msg{padding:17px 0;border-bottom:1px solid var(--line);max-width:900px}
.msg:last-child{border-bottom:0}
.who{font:700 10px/1 var(--mono);letter-spacing:.12em;text-transform:uppercase;
  color:var(--faded);margin-bottom:8px}
.msg.user .who{color:var(--accent)}
.body{overflow-wrap:anywhere;font:13.5px/1.7 var(--sans)}
.body>*:first-child{margin-top:0}
.body>*:last-child{margin-bottom:0}
.body p{margin:0 0 10px}
.body h1,.body h2,.body h3,.body h4,.body h5,.body h6{
  font:700 14px/1.4 var(--sans);margin:18px 0 8px;letter-spacing:-.005em}
.body h1{font-size:17px}
.body h2{font-size:15.5px}
.body ul,.body ol{margin:0 0 10px;padding-left:22px}
.body li{margin:3px 0}
.body li::marker{color:var(--faded)}
.body code{font:12.5px/1.5 var(--mono);background:var(--sel);padding:1px 5px;
  border-radius:4px;border:1px solid var(--line)}
.body pre{background:var(--sel);border:1px solid var(--line);border-radius:6px;
  padding:11px 13px;margin:0 0 11px;overflow-x:auto;white-space:pre}
.body pre code{background:0;border:0;padding:0;font-size:12.5px;line-height:1.6}
.body blockquote{margin:0 0 11px;padding:2px 0 2px 13px;color:var(--faded);
  border-left:2px solid var(--line)}
.body a{color:var(--accent)}
.body hr{border:0;border-top:1px solid var(--line);margin:16px 0}
.body table{border-collapse:collapse;margin:0 0 11px;display:block;overflow-x:auto;
  font-size:12.5px}
.body th,.body td{border:1px solid var(--line);padding:5px 9px;text-align:left}
.body th{background:var(--sel);font-weight:700}
.hint{color:var(--faded);font:400 14px/1.6 var(--sans);padding:56px 26px;text-align:center}
.empty{color:var(--faded);font:400 13px/1.6 var(--sans);padding:36px 18px;text-align:center}

@media(max-width:820px){
  .panes{flex-direction:column}
  .left{width:auto;max-height:44vh;border-right:0;border-bottom:1px solid var(--line)}
}
</style></head><body>
<header>
  <span class="mark">Claude <span>Déjà Vu</span></span>
  <input id="q" placeholder="Search every conversation…" aria-label="Search conversations">
  <div class="scope" role="group" aria-label="Time range">
    <button data-scope="48h" class="on">48h</button>
    <button data-scope="7d">7 days</button>
    <button data-scope="all">All</button>
  </div>
  <button id="analyze">Cross-reference</button>
  <span id="msg"></span>
</header>
<div id="chips"></div>
<div class="panes">
  <div class="left">
    <div class="count" id="count"></div>
    <div id="list"></div>
  </div>
  <div class="right">
    <div class="dtop" id="dtop" style="display:none">
      <div class="dtop-text">
        <div class="eyebrow" id="d-proj"></div><h2 id="d-title"></h2>
      </div>
      <button id="d-close" title="Close (Esc)" aria-label="Close conversation">Close ✕</button>
    </div>
    <div id="thread"><div class="hint">Select a conversation to read it here.</div></div>
  </div>
</div>
<script>
let CLUSTER=null, SCOPE='48h', SELECTED=null, DATA={sessions:[],clusters:[]};
const SCOPES_OK=['48h','7d','all'];
function esc(s){return (s||'').replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}
function rel(t){const d=Date.now()/1000-t;if(d<3600)return Math.round(d/60)+'m';
  if(d<86400)return Math.round(d/3600)+'h';return Math.round(d/86400)+'d'}
function proj(p){return p.split('/').slice(-2).join('/')}
// Highlight every case-insensitive match of q, escaping each slice safely.
function highlight(s,q){s=s||'';if(!q)return esc(s);
  const low=s.toLowerCase(),ql=q.toLowerCase();let out='',i=0,j;
  while((j=low.indexOf(ql,i))>=0){
    out+=esc(s.slice(i,j))+'<mark>'+esc(s.slice(j,j+q.length))+'</mark>';i=j+q.length}
  return out+esc(s.slice(i))}
function qval(){return document.getElementById('q').value.trim()}
// --- minimal markdown -> html (no library; messages are mostly markdown) ---
function mdInline(s){s=esc(s);
  s=s.replace(/`([^`]+)`/g,(m,c)=>'<code>'+c+'</code>');
  s=s.replace(/\\*\\*([^*]+)\\*\\*/g,'<strong>$1</strong>');
  s=s.replace(/(^|[^*\\w])\\*([^*\\n]+)\\*/g,'$1<em>$2</em>');
  s=s.replace(/\\[([^\\]]+)\\]\\((https?:[^)\\s]+)\\)/g,
    '<a href="$2" target="_blank" rel="noopener">$1</a>');
  return s}
function mdRow(l){return l.trim().replace(/^\\||\\|$/g,'').split('|').map(c=>c.trim())}
function md(text){
  const L=(text||'').split('\\n');let out='',i=0;
  const starter=l=>/^\\s*(```|#{1,6}\\s|>|([-*+]|\\d+\\.)\\s)/.test(l)||/^\\s*\\|.*\\|\\s*$/.test(l);
  while(i<L.length){const ln=L[i];
    if(/^\\s*```/.test(ln)){let b=[];i++;
      while(i<L.length&&!/^\\s*```/.test(L[i])){b.push(L[i]);i++}
      i++;out+='<pre><code>'+esc(b.join('\\n'))+'</code></pre>';continue}
    const h=ln.match(/^(#{1,6})\\s+(.*)$/);
    if(h){const n=h[1].length;out+='<h'+n+'>'+mdInline(h[2])+'</h'+n+'>';i++;continue}
    if(/^\\s*(---+|\\*\\*\\*+|___+)\\s*$/.test(ln)){out+='<hr>';i++;continue}
    if(/^\\s*\\|.*\\|\\s*$/.test(ln)&&i+1<L.length&&/^[\\s|:-]+$/.test(L[i+1])&&L[i+1].includes('-')){
      const head=mdRow(ln);i+=2;let rows=[];
      while(i<L.length&&/^\\s*\\|.*\\|/.test(L[i])){rows.push(mdRow(L[i]));i++}
      out+='<table><thead><tr>'+head.map(c=>'<th>'+mdInline(c)+'</th>').join('')
        +'</tr></thead><tbody>'+rows.map(r=>'<tr>'+r.map(c=>'<td>'+mdInline(c)+'</td>')
        .join('')+'</tr>').join('')+'</tbody></table>';continue}
    if(/^\\s*>\\s?/.test(ln)){let b=[];
      while(i<L.length&&/^\\s*>\\s?/.test(L[i])){b.push(L[i].replace(/^\\s*>\\s?/,''));i++}
      out+='<blockquote>'+md(b.join('\\n'))+'</blockquote>';continue}
    if(/^\\s*([-*+]|\\d+\\.)\\s+/.test(ln)){const ord=/^\\s*\\d+\\./.test(ln);let items=[];
      while(i<L.length&&/^\\s*([-*+]|\\d+\\.)\\s+/.test(L[i])){
        let it=L[i].replace(/^\\s*([-*+]|\\d+\\.)\\s+/,'');i++;
        while(i<L.length&&/^\\s{2,}\\S/.test(L[i])&&!/^\\s*([-*+]|\\d+\\.)\\s+/.test(L[i])){
          it+='\\n'+L[i].trim();i++}
        items.push(it)}
      out+=(ord?'<ol>':'<ul>')+items.map(t=>'<li>'+mdInline(t).replace(/\\n/g,'<br>')+'</li>')
        .join('')+(ord?'</ol>':'</ul>');continue}
    if(/^\\s*$/.test(ln)){i++;continue}
    let b=[];
    while(i<L.length&&!/^\\s*$/.test(L[i])&&!starter(L[i])){b.push(L[i]);i++}
    if(b.length)out+='<p>'+mdInline(b.join('\\n')).replace(/\\n/g,'<br>')+'</p>';else i++}
  return out}
// Wrap search matches in already-rendered HTML by walking text nodes only,
// so highlighting can never break the markdown markup.
function markMatches(root,q){if(!q)return;const ql=q.toLowerCase();
  const w=document.createTreeWalker(root,NodeFilter.SHOW_TEXT),nodes=[];
  while(w.nextNode())if(w.currentNode.nodeValue.toLowerCase().includes(ql))nodes.push(w.currentNode);
  nodes.forEach(n=>{const t=n.nodeValue,f=document.createDocumentFragment();let i=0,j;
    while((j=t.toLowerCase().indexOf(ql,i))>=0){
      if(j>i)f.appendChild(document.createTextNode(t.slice(i,j)));
      const m=document.createElement('mark');m.textContent=t.slice(j,j+q.length);
      f.appendChild(m);i=j+q.length}
    if(i<t.length)f.appendChild(document.createTextNode(t.slice(i)));
    n.parentNode.replaceChild(f,n)})}
// Keep the address bar in step with what's on screen, so any view can be linked.
function syncURL(){const p=new URLSearchParams(),q=qval();
  if(q)p.set('q',q);
  if(SCOPE!=='48h')p.set('scope',SCOPE);
  const qs=p.toString();
  history.replaceState(null,'',location.pathname+(qs?'?'+qs:'')
    +(SELECTED?'#'+encodeURIComponent(SELECTED):''))}
async function load(){
  const r=await fetch('/api/sessions?q='+encodeURIComponent(qval())+'&scope='+SCOPE);
  DATA=await r.json();render();renderChips();syncURL();
  // #<session-id> opens that conversation directly, so a link to one can be bookmarked.
  const h=decodeURIComponent(location.hash.slice(1));
  if(h&&h!==SELECTED)openDetail(h)}
function renderChips(){const el=document.getElementById('chips');el.innerHTML='';
  const cs=DATA.clusters||[];
  if(!cs.length){
    if(DATA.analyzed)return;
    el.innerHTML='<span class=lbl>Topics</span><span class=hint-inline>'
      +'Run Cross-reference to group related conversations across projects.</span>';
    return}
  const lbl=document.createElement('span');lbl.className='lbl';lbl.textContent='Topics';
  el.appendChild(lbl);
  const all=DATA.sessions||[];
  cs.forEach(c=>{const n=all.filter(s=>(s.clusters||[]).includes(c)).length;
    const s=document.createElement('button');
    s.className='chip'+(c===CLUSTER?' on':'');
    s.innerHTML=esc(c)+'<span class=n>'+n+'</span>';
    s.title=n+(n===1?' conversation':' conversations')+' in this topic';
    s.onclick=()=>{CLUSTER=(CLUSTER===c?null:c);render();renderChips()};el.appendChild(s)})}
function visible(){let ss=DATA.sessions||[];
  return CLUSTER?ss.filter(s=>(s.clusters||[]).includes(CLUSTER)):ss}
function render(){
  const q=qval(),ss=visible();
  const list=document.getElementById('list'),cnt=document.getElementById('count');
  if(!ss.length){cnt.textContent='no matches';
    list.innerHTML='<div class=empty>'+(q?'Nothing found for “'+esc(q)+'”.'
      :'No conversations in this range.')+'</div>';return}
  cnt.textContent=ss.length+(ss.length===1?' conversation':' conversations');
  const now=Date.now()/1000;
  list.innerHTML=ss.map(s=>{
    const recent=(now-s.last)<48*3600;
    const tags=(s.clusters||[]).map(c=>'<span class=tag>'+esc(c)+'</span>').join('');
    const snip=s.snippet?'<div class=snippet>'+highlight(s.snippet,q)+'</div>':'';
    const sum=s.summary?'<div class=summary>'+esc(s.summary)+'</div>':'';
    return '<div class="row'+(recent?' recent':'')+(s.id===SELECTED?' on':'')
      +'" data-id="'+esc(s.id)+'" tabindex=0>'
      +'<div class=rtop><span class=eyebrow>'+esc(proj(s.project))+'</span>'
      +'<span class=when>'+rel(s.last)+' · '+s.count+'</span></div>'
      +'<div class=title>'+esc(s.title)+'</div>'+sum
      +(tags?'<div class=tags>'+tags+'</div>':'')+snip+'</div>'}).join('')}
function closeDetail(){SELECTED=null;syncURL();
  document.querySelectorAll('.row').forEach(r=>r.classList.remove('on'));
  document.getElementById('dtop').style.display='none';
  document.getElementById('thread').innerHTML=
    '<div class="hint">Select a conversation to read it here.</div>'}
async function openDetail(id){
  SELECTED=id;syncURL();
  document.querySelectorAll('.row').forEach(r=>r.classList.toggle('on',r.dataset.id===id));
  const q=qval(),thread=document.getElementById('thread');
  thread.innerHTML='<div class=hint>Loading…</div>';
  let d;try{const r=await fetch('/api/session?id='+encodeURIComponent(id));
    if(!r.ok)throw 0;d=await r.json()}catch(e){
    thread.innerHTML='<div class=hint>This conversation could not be read.</div>';return}
  document.getElementById('dtop').style.display='';
  document.getElementById('d-proj').textContent=proj(d.project||'');
  document.getElementById('d-title').textContent=d.title||'(untitled session)';
  thread.innerHTML=(d.messages||[]).map(m=>
    '<div class="msg '+(m.role==='user'?'user':'asst')+'">'
    +'<div class=who>'+(m.role==='user'?'You':'Claude')+'</div>'
    +'<div class=body>'+md(m.text)+'</div></div>').join('')
    ||'<div class=hint>No messages in this conversation.</div>';
  markMatches(thread,q);
  thread.scrollTop=0;
  const mk=thread.querySelector('mark');
  if(mk)mk.scrollIntoView({block:'center'});  // seek to first match
}
function toggleDetail(id){id===SELECTED?closeDetail():openDetail(id)}
document.getElementById('list').addEventListener('click',e=>{
  const r=e.target.closest('.row');if(r&&r.dataset.id)toggleDetail(r.dataset.id)});
document.getElementById('list').addEventListener('keydown',e=>{
  if(e.key!=='Enter')return;const r=e.target.closest('.row');
  if(r&&r.dataset.id)toggleDetail(r.dataset.id)});
document.getElementById('d-close').addEventListener('click',closeDetail);
document.addEventListener('keydown',e=>{
  if(e.key==='Escape'&&SELECTED)closeDetail()});
document.querySelectorAll('.scope button').forEach(b=>b.onclick=()=>{
  SCOPE=b.dataset.scope;
  document.querySelectorAll('.scope button').forEach(x=>x.classList.toggle('on',x===b));
  load()});
document.getElementById('q').addEventListener('input',debounce(load,200));
document.getElementById('analyze').addEventListener('click',async()=>{
  const m=document.getElementById('msg');m.textContent='Reading your conversations…';
  try{const r=await fetch('/api/analyze',{method:'POST'});const d=await r.json();
    m.textContent=d.ok?'Cross-referenced.':('Couldn\\u2019t reach Claude — '+d.error);
    if(d.ok)load()}catch(e){m.textContent='Couldn\\u2019t reach Claude.'}});
function debounce(f,ms){let t;return(...a)=>{clearTimeout(t);t=setTimeout(()=>f(...a),ms)}}
// ?q=term&scope=7d prefills the view, so a search can be linked or bookmarked.
(function(){const p=new URLSearchParams(location.search);
  if(p.get('q'))document.getElementById('q').value=p.get('q');
  const sc=p.get('scope');
  if(sc&&SCOPES_OK.includes(sc)){SCOPE=sc;
    document.querySelectorAll('.scope button')
      .forEach(b=>b.classList.toggle('on',b.dataset.scope===sc))}})();
load();
</script></body></html>"""


# --- selftest ----------------------------------------------------------------

def _selftest():
    import tempfile
    lines = [
        {"type": "custom-title", "customTitle": "My Title"},
        {"type": "user", "message": {"role": "user", "content": "<system-reminder>x"},
         "isMeta": True, "timestamp": "2026-08-10T10:00:00.000Z"},
        {"type": "user", "message": {"role": "user", "content": "real first prompt"},
         "timestamp": "2026-08-10T10:00:05.000Z"},
        "{ this is not valid json",
        {"type": "assistant",
         "message": {"role": "assistant", "content": [{"type": "text", "text": "hello kafka"}]},
         "timestamp": "2026-08-10T11:00:00.000Z", "cwd": "/repo/a", "gitBranch": "main"},
    ]
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
        for o in lines:
            f.write(o if isinstance(o, str) else json.dumps(o))
            f.write("\n")
        path = f.name
    s = parse_session(path)
    os.unlink(path)
    assert s["title"] == "My Title", s["title"]
    assert s["count"] == 3, s["count"]  # 2 user + 1 assistant; malformed skipped
    assert s["project"] == "/repo/a" and s["branch"] == "main"
    assert abs(s["first"] - _epoch("2026-08-10T10:00:00.000Z")) < 1
    assert abs(s["last"] - _epoch("2026-08-10T11:00:00.000Z")) < 1
    assert "kafka" in s["blob"]

    # title fallback when no custom-title
    s2 = dict(s); s2["blob"] = "alpha beta gamma delta"
    assert _snippet(s2["blob"], "gamma", 8).strip("…").find("gamma") >= 0

    # sampling covers start+middle+end
    blob = "S" * 1000 + "MID" + "E" * 1000
    samp = sample_text(blob, 300)
    assert "MID" in samp and samp.startswith("S") and samp.endswith("E")

    # merge tolerates missing/extra ids
    sessions = [{"id": "a", "blob": ""}, {"id": "b", "blob": ""}]
    insights = {"summaries": {"a": "did X", "zzz": "ghost"},
                "clusters": [{"label": "topic", "session_ids": ["a", "missing"]}]}
    merge_insights(sessions, insights)
    assert sessions[0]["summary"] == "did X" and sessions[0]["clusters"] == ["topic"]
    assert sessions[1]["summary"] is None and sessions[1]["clusters"] == []

    # transcript: ordered messages, title, and id validation (no path traversal)
    global PROJECTS_DIR
    tmp = tempfile.mkdtemp()
    saved = PROJECTS_DIR
    PROJECTS_DIR = tmp
    try:
        with open(os.path.join(tmp, "sess-1.jsonl"), "w") as fh:
            for o in [
                {"type": "user", "message": {"role": "user", "content": "first q"},
                 "timestamp": "2026-08-10T10:00:00.000Z", "cwd": "/repo/x"},
                {"type": "assistant",
                 "message": {"role": "assistant", "content": [{"type": "text", "text": "reply"}]}},
            ]:
                fh.write(json.dumps(o) + "\n")
        tr = read_transcript("sess-1")
        assert tr["title"] == "first q" and tr["project"] == "/repo/x"
        assert [m["role"] for m in tr["messages"]] == ["user", "assistant"]
        assert tr["messages"][1]["text"] == "reply"
        assert read_transcript("missing") is None
        assert read_transcript("../../etc/passwd") is None  # rejected by ID_RE
    finally:
        PROJECTS_DIR = saved

    print("selftest ok")


def main():
    if "--selftest" in sys.argv:
        _selftest()
        return
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Claude Déjà Vu: http://127.0.0.1:{PORT}  (Ctrl-C to stop)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
