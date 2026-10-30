#!/usr/bin/env python3
"""Trajectory live-GitHub companion: loopback-only execution host.

The native iOS workbench (simulator) drives this server over host-local
HTTP. Git, Go, the native Muse CLI, and GitHub authentication stay on the
Mac; provider and GitHub credentials never enter the iOS bundle.

Endpoints (JSON):
  GET  /status                                   server info (read-only)
  POST /sessions                                 create session {session_id}
  GET  /sessions/<sid>                           full session state (read-only)
  POST /sessions/<sid>/import   {repo, ref}      pinned-clone import (job)
  POST /sessions/<sid>/accept   {answer}         intent-only change (inline)
  POST /sessions/<sid>/generate {candidate}      Muse source generation (job)
  POST /sessions/<sid>/construct {candidate, answer, parent_candidate?, parent_tree?}
                                                 accept + construct (one job)
  POST /sessions/<sid>/check    {candidate}      go build/vet/test/scenario (job)
  POST /sessions/<sid>/commit   {candidate, message}  explicit commit (job)
  POST /sessions/<sid>/push     {candidate}      explicit push (job)
  POST /sessions/<sid>/observe  {commit, timeout_s}    Actions run watch (job)
  GET  /sessions/<sid>/jobs/<jid>                job status (read-only)
  POST /sessions/<sid>/jobs/<jid>/cancel         cancel a running job
  GET  /sessions/<sid>/diff?candidate=X          unified diff vs parent (read-only)
  GET  /sessions/<sid>/source?candidate=X&path=P file text (read-only)

Jobs are asynchronous with bounded progress and cancellation. Mutations
are serialized per session; repeated identical mutation requests return
the in-flight job instead of starting a duplicate. GET reads never mutate
source or refresh evidence by writing.

State lives under <state_dir>/sessions/<sid>.json plus an append-only
<state_dir>/events.jsonl. Candidate workspaces live under
<state_dir>/candidates/<sid>/<name>/ with a pristine parent snapshot at
<state_dir>/parents/<sid>/<name>/ for diffing and boundary checks.
"""

import copy
import difflib
import filecmp
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import threading
import time
import urllib.parse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE_DIR = os.environ.get(
    "TRAJECTORY_COMPANION_STATE",
    os.path.join(os.path.expanduser("~"), ".trajectory-nebius", "state"),
)
MUSE_BIN = os.environ.get("TRAJECTORY_MUSE_BIN", "muse")
MUSE_MODEL = os.environ.get("TRAJECTORY_MUSE_MODEL", "muse-spark-1.3")
GENERATE_TIMEOUT_S = int(os.environ.get("TRAJECTORY_GENERATE_TIMEOUT_S", "900"))
OBSERVE_DEFAULT_TIMEOUT_S = int(os.environ.get("TRAJECTORY_OBSERVE_TIMEOUT_S", "600"))

ANSWERS = ("queue_time", "delivery_time")
# First-milestone scope: the dedicated private demo repo is the only
# import target; candidate names and session ids are path-safe tokens.
ALLOWED_REPOS = ("instagrim-dev/trajectory-live-demo", "instagrim-dev/trajectory-nebius-demo")


def check_token(value, kind):
    pattern = r"^[0-9a-f]{12}$" if kind == "session" else r"^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$"
    if not isinstance(value, str) or re.match(pattern, value) is None:
        raise ValueError(f"invalid {kind} token")
    return value
# NOTE: no test-only operation registry exists on purpose. Every server
# operation is a real product path; cancellation tests drive the same
# JobManager machinery in-process instead of calling a fake endpoint.
# Generator mutation boundary: only these repo-relative paths may change.
WRITABLE = {"queued/queue.go", "queued/worker.go"}
# Coordinator-owned / protected: a generation touching these is rejected.
PROTECTED_PREFIXES = ("queued/queued_test.go", "queued/support_test.go",
                      ".trajectory/", ".github/", "go.mod", "cmd/")
CHECKER_ID = "trajectory-companion/1: go build + go vet + go test + exportdemo scenario"
PREVIEW_FILE_LIMIT = 32 * 1024
PREVIEW_DIFF_LIMIT = 32 * 1024
CONSTRUCTION_EVENT_LIMIT = 64
GENERATION_POLL_INTERVAL_S = 0.2


def utcnow():
    return datetime.now(timezone.utc).isoformat()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def tree_snapshot(root):
    """Map repo-relative path -> sha256 for all tracked working files."""
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
        if any(os.path.islink(os.path.join(dirpath, d)) for d in dirnames):
            raise ValueError("symlinks are not allowed in candidate source trees")
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for name in filenames:
            full = os.path.join(dirpath, name)
            if not stat.S_ISREG(os.lstat(full).st_mode):
                raise ValueError("only regular files are allowed in candidate source trees")
            rel = os.path.relpath(full, root)
            out[rel] = sha256_file(full)
    return out


def tree_hash(snapshot):
    items = "".join(f"{p}\x00{snapshot[p]}\x00" for p in sorted(snapshot))
    return hashlib.sha256(items.encode()).hexdigest()


def preview_source(root, rel):
    """Read only a bounded regular source file, without following symlinks.

    Directory-relative opens also protect the queued directory itself.
    A file changing during the read is omitted until a later observation.
    No provider output, arbitrary path, or raw agent log enters previews.
    """
    if rel not in WRITABLE:
        raise ValueError("preview path is outside the construction boundary")
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    if not nofollow:
        raise ValueError("safe source previews require O_NOFOLLOW")
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | nofollow)
    try:
        queued_fd = os.open("queued", os.O_RDONLY | os.O_DIRECTORY | nofollow,
                            dir_fd=root_fd)
        try:
            fd = os.open(rel.split("/")[1], os.O_RDONLY | nofollow | os.O_NONBLOCK,
                         dir_fd=queued_fd)
            try:
                before = os.fstat(fd)
                if not stat.S_ISREG(before.st_mode) or before.st_size > PREVIEW_FILE_LIMIT:
                    raise ValueError("preview file is not a bounded regular file")
                chunks, total = [], 0
                while total <= PREVIEW_FILE_LIMIT:
                    data = os.read(fd, min(8192, PREVIEW_FILE_LIMIT + 1 - total))
                    if not data:
                        break
                    chunks.append(data)
                    total += len(data)
                after = os.fstat(fd)
                if total > PREVIEW_FILE_LIMIT:
                    raise ValueError("preview file exceeds the byte limit")
                if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                    raise ValueError("preview file changed during observation")
                raw = b"".join(chunks)
                return raw.decode("utf-8"), hashlib.sha256(raw).hexdigest()
            finally:
                os.close(fd)
        finally:
            os.close(queued_fd)
    finally:
        os.close(root_fd)


def run(cmd, cwd=None, env=None, timeout=300, cancel=None, input_bytes=None):
    """Run a command; poll for cancellation. Returns (rc, stdout, stderr).

    Stdout/stderr stream to temp files while waiting, so a verbose child
    can never wedge the parent on a full pipe; cancellation and timeout
    terminate the whole process group (see kill_tree). Retained output is
    capped at the tail 512 KiB per stream."""
    import tempfile
    out_f = tempfile.TemporaryFile(prefix="traj-out-")
    err_f = tempfile.TemporaryFile(prefix="traj-err-")
    try:
        proc = subprocess.Popen(
            cmd, cwd=cwd, env=env,
            stdin=subprocess.PIPE if input_bytes else None,
            stdout=out_f, stderr=err_f, start_new_session=True,
        )
        if input_bytes:
            try:
                proc.stdin.write(input_bytes)
                proc.stdin.close()
            except BrokenPipeError:
                pass
        deadline = time.time() + timeout
        outcome = None
        while True:
            if cancel is not None and cancel.is_set():
                kill_tree(proc)
                proc.wait()
                outcome = ("cancelled", "cancelled by operator")
                break
            rc = proc.poll()
            if rc is not None:
                outcome = (rc, "")
                break
            if time.time() > deadline:
                kill_tree(proc)
                proc.wait()
                outcome = ("timeout", f"exceeded {timeout}s")
                break
            time.sleep(0.2)
        rc, err_note = outcome
        out, err = _read_tail(out_f), _read_tail(err_f)
        if err_note and not err:
            err = err_note
        elif err_note:
            err = err + "\n" + err_note
        return (rc, out, err)
    finally:
        out_f.close()
        err_f.close()


def _read_tail(fobj, limit=512 * 1024):
    """Read the tail of a temp-file stream as text (bounded)."""
    try:
        fobj.seek(0, os.SEEK_END)
        size = fobj.tell()
        fobj.seek(max(0, size - limit))
        return fobj.read().decode("utf-8", "replace")
    except OSError:
        return ""


def scrub_env_for_generator():
    """Environment for nested Muse generation: provider key inherited via
    process env (passed to stdin, never logged), GitHub credentials removed,
    git non-interactive so no push/auth can succeed from inside."""
    keep = ("PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "TEMP", "TMP",
            "LANG", "LC_ALL", "TERM", "SHELL", "GOFLAGS",
            "GOPATH", "GOCACHE", "HOMEBREW_PREFIX", "HOMEBREW_CELLAR")
    env = {k: v for k, v in os.environ.items() if k in keep}
    key_name = {"azure_openai": "AZURE_OPENAI_API_KEY", "meta": "META_API_KEY",
                "baseten": "BASETEN_API_KEY", "nebius": "NEBIUS_API_KEY"}[generator_identity()["provider"]]
    if os.environ.get(key_name):
        env[key_name] = os.environ[key_name]
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GIT_CONFIG_COUNT"] = "1"
    env["GIT_CONFIG_KEY_0"] = "credential.helper"
    env["GIT_CONFIG_VALUE_0"] = ""
    return env


def generator_identity():
    provider = os.environ.get("TRAJECTORY_GENERATOR_PROVIDER", "meta")
    if provider not in ("meta", "azure_openai", "baseten", "nebius"):
        raise ValueError("unsupported generator provider")
    return {"provider": provider,
            "agent": "codex exec" if provider == "azure_openai" else ("Nebius Token Factory" if provider == "nebius" else "muse exec"),
            "model": os.environ.get("TRAJECTORY_GENERATOR_MODEL", "nvidia/Nemotron-3_5-Lightning" if provider == "nebius" else ("meta-models/muse-spark-open-1026" if provider == "baseten" else MUSE_MODEL))}


def generator_command(identity, workspace, prompt_path, invocation_id):
    """Build a selected-provider invocation; secrets never enter argv or receipts."""
    if identity["provider"] == "nebius":
        if not os.environ.get("NEBIUS_API_KEY"):
            raise RuntimeError("Nebius provider key unavailable to generator")
        return ([sys.executable, os.path.join(os.path.dirname(__file__), "nebius_generate.py"),
                 "--workspace", workspace, "--prompt", prompt_path,
                 "--model", identity["model"], "--invocation-id", invocation_id], b"")
    if identity["provider"] == "azure_openai":
        if not os.environ.get("AZURE_OPENAI_API_KEY"):
            raise RuntimeError("Azure provider key unavailable to generator")
        base = os.environ.get("AZURE_OPENAI_BASE_URL", "")
        if not base.startswith("https://"):
            raise RuntimeError("Azure OpenAI HTTPS endpoint unavailable")
        args = [os.environ.get("TRAJECTORY_CODEX_BIN", "codex"), "exec",
                "--ignore-user-config", "--ephemeral", "--skip-git-repo-check",
                "--sandbox", "workspace-write", "--json", "--cd", workspace,
                "--model", identity["model"]]
        for key, value in {
            "model_provider": "azure",
            "model_providers.azure.name": "Azure OpenAI",
            "model_providers.azure.base_url": base,
            "model_providers.azure.env_key": "AZURE_OPENAI_API_KEY",
            "model_providers.azure.wire_api": "responses",
            "model_reasoning_effort": "low",
            "approval_policy": "never", "web_search": "disabled",
        }.items():
            args.extend(["-c", key + "=" + json.dumps(value)])
        with open(prompt_path, "rb") as prompt_file:
            prompt = prompt_file.read()
        return args + ["-"], prompt
    key_name = "BASETEN_API_KEY" if identity["provider"] == "baseten" else "META_API_KEY"
    if not os.environ.get(key_name):
        raise RuntimeError("provider key unavailable to generator")
    args = [MUSE_BIN, "exec", "--provider", "meta", "--model", identity["model"],
            "--workspace", workspace, "--worktree", "off", "--approval-mode", "never",
            "--trust-workspace", "--disable-sandbox", "--disable-reminders",
            "--disable-request-user-input", "--disable-web-tools", "--max-model-steps", "60",
            "--session-id", invocation_id, "--api-key-stdin", "--json",
            "--prompt-file", prompt_path]
    if identity["provider"] == "baseten":
        args.extend(["-c", "endpoint_transport=" + json.dumps({
            "base_url": "https://inference.baseten.co/v1", "auth": "bearer"}),
            "--no-parallel-tool-calls", "--reasoning-effort", "low"])
    return args, os.environ[key_name].encode() + b"\n"


def generator_session_id(events_path, fallback):
    with open(events_path, encoding="utf-8", errors="replace") as stream:
        for line in stream:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("type") == "thread.started" and event.get("thread_id"):
                return event["thread_id"]
    return fallback


def git_env():
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"
    return env


def kill_tree(proc):
    """Terminate the whole process group (leader + spawned children)."""
    import signal
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        try:
            proc.kill()
        except ProcessLookupError:
            pass


# ---------------------------------------------------------------- store ---

class Store:
    def __init__(self, root):
        self.root = root
        self.lock = threading.RLock()
        os.makedirs(os.path.join(root, "sessions"), exist_ok=True)
        self._events = open(os.path.join(root, "events.jsonl"), "a", encoding="utf-8")

    def close(self):
        with self.lock:
            try:
                self._events.close()
            except OSError:
                pass

    def log(self, kind, session_id, payload):
        with self.lock:
            rec = {"at": utcnow(), "kind": kind, "session": session_id,
                   "payload": payload}
            self._events.write(json.dumps(rec) + "\n")
            self._events.flush()

    def path(self, sid):
        return os.path.join(self.root, "sessions", sid + ".json")

    def load(self, sid):
        with self.lock:
            p = self.path(sid)
            if not os.path.exists(p):
                return None
            with open(p, encoding="utf-8") as f:
                return json.load(f)

    def save(self, session, jobs_authoritative=False):
        with self.lock:
            # Operations own session content under the session lock, but
            # job submissions can arrive while a long operation runs.
            # A stale operation snapshot must not erase durable attempts.
            current = self.load(session["session_id"])
            if current is not None and not jobs_authoritative:
                session = copy.deepcopy(session)
                session["jobs"] = current.get("jobs", {})
            tmp = self.path(session["session_id"]) + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(session, f, indent=2, sort_keys=True)
                f.write("\n")
            os.replace(tmp, self.path(session["session_id"]))

    def update_job(self, sid, jid, fields):
        """Atomic bookkeeping update without overwriting newer candidates."""
        with self.lock:
            session = self.load(sid)
            if session is None:
                return None
            entry = session.setdefault("jobs", {}).get(jid, {})
            entry.update(copy.deepcopy(fields))
            session["jobs"][jid] = entry
            self.save(session, jobs_authoritative=True)
            return copy.deepcopy(entry)

    def new_session(self):
        import uuid
        sid = uuid.uuid4().hex[:12]
        session = {
            "session_id": sid,
            "created_at": utcnow(),
            "repo": None,
            "accepted_answer": None,
            "intents": [],
            "candidates": {},
            "verifications": [],
            "commits": [],
            "runs": [],
            "jobs": {},
        }
        self.save(session)
        self.log("session_created", sid, {})
        return session


# ---------------------------------------------------------------- jobs ----

class JobManager:
    """Async jobs with progress, cancellation, per-session serialization,
    and mutation deduplication (same idempotency key returns the job)."""

    def __init__(self, store):
        self.store = store
        self.lock = threading.RLock()
        self.jobs = {}          # jid -> job record (live)
        self.session_locks = {}  # sid -> threading.Lock
        self.inflight = {}      # (sid, idempotency_key) -> jid

    def session_lock(self, sid):
        with self.lock:
            return self.session_locks.setdefault(sid, threading.Lock())

    def submit(self, sid, op, params, fn, idempotency_key=None, cancellable=True,
               construction=None):
        import uuid
        with self.lock:
            if idempotency_key is not None:
                key = (sid, idempotency_key)
                jid = self.inflight.get(key)
                if jid is not None and jid in self.jobs:
                    job = self.jobs[jid]
                    if job["status"] in ("queued", "running"):
                        return job, False
            jid = uuid.uuid4().hex[:12]
            job = {
                "job_id": jid, "session": sid, "op": op, "params": params,
                "status": "queued", "progress": 0.0, "note": "queued",
                "created_at": utcnow(), "finished_at": None,
                "result": None, "error": None,
                "cancel_requested": False, "cancellable": cancellable,
            }
            self.jobs[jid] = job
            if construction is not None:
                job["construction"] = copy.deepcopy(construction)
                self._construction_update_locked(
                    job, "queued", "queued", "Construction request queued.")
            if idempotency_key is not None:
                self.inflight[(sid, idempotency_key)] = jid
            reservation = {"job_id": jid, "session": sid, "op": op,
                           "params": copy.deepcopy(params), "status": "queued",
                           "created_at": job["created_at"]}
            if construction is not None:
                reservation["construction"] = copy.deepcopy(job["construction"])
            self.store.update_job(sid, jid, reservation)
        cancel = threading.Event()
        job["_cancel"] = cancel
        job["_key"] = (sid, idempotency_key) if idempotency_key else None

        def runner():
            with self.session_lock(sid):
                with self.lock:
                    queued_cancel = cancel.is_set()
                    job["status"] = "running"
                    job["note"] = "running"
                self._update_session_job(sid, jid, "running", None)
                if queued_cancel:
                    # Cancelled while queued behind another mutation: never
                    # run, last valid state untouched.
                    with self.lock:
                        job["status"] = "cancelled"
                        job["note"] = ("cancelled while queued; "
                                       "never ran; state preserved")
                        job["finished_at"] = utcnow()
                        self._finish_construction_locked(job)
                    self._update_session_job(sid, jid, "cancelled", None,
                                             "cancelled while queued")
                    with self.lock:
                        key = job.pop("_key", None)
                        job.pop("_cancel", None)
                        if key is not None and self.inflight.get(key) == jid:
                            del self.inflight[key]
                    return
                try:
                    result = fn(job, cancel, lambda f, n: self._progress(jid, f, n))
                    with self.lock:
                        if cancel.is_set() and job["status"] == "running":
                            job["status"] = "cancelled"
                            job["note"] = "cancelled; last valid state preserved"
                        else:
                            job["status"] = "succeeded"
                            job["progress"] = 1.0
                            job["result"] = result
                        job["finished_at"] = utcnow()
                except Exception as e:  # noqa: BLE001 - surfaced as job error
                    with self.lock:
                        job["status"] = "failed" if not cancel.is_set() else "cancelled"
                        job["error"] = f"{type(e).__name__}: {e}"
                        job["finished_at"] = utcnow()
                finally:
                    with self.lock:
                        self._finish_construction_locked(job)
                        key = job.pop("_key", None)
                        job.pop("_cancel", None)
                        if key is not None and self.inflight.get(key) == jid:
                            del self.inflight[key]
                    self._update_session_job(
                        sid, jid, job["status"], job.get("result"), job.get("error"))

        threading.Thread(target=runner, daemon=True,
                         name=f"job-{jid}").start()
        return job, True

    def _construction_update_locked(self, job, stage, kind, message, **fields):
        construction = job.get("construction")
        if construction is None:
            return
        construction.update(copy.deepcopy(fields))
        if stage is not None:
            construction["stage"] = stage
        if kind is not None:
            seq = job.get("_construction_seq", 0) + 1
            job["_construction_seq"] = seq
            event = {"id": f"{job['job_id']}:{seq}", "at": utcnow(),
                     "kind": kind, "message": str(message)[:600]}
            construction["events"] = (construction.get("events", [])
                                      + [event])[-CONSTRUCTION_EVENT_LIMIT:]

    def construction_update(self, jid, stage=None, kind=None, message=None,
                            **fields):
        with self.lock:
            job = self.jobs.get(jid)
            if job is not None:
                self._construction_update_locked(job, stage, kind, message,
                                                 **fields)

    def _finish_construction_locked(self, job):
        construction = job.get("construction")
        if construction is None:
            return
        status = job["status"]
        if status not in ("succeeded", "failed", "cancelled"):
            return
        fields = {"provisional": False}
        if status != "succeeded":
            fields.update(files=[], error=job.get("error") or
                          "Construction cancelled; no candidate published.")
            construction.pop("output_tree", None)
        self._construction_update_locked(
            job, status, status,
            "Candidate published after exit and boundary checks."
            if status == "succeeded" else
            "No candidate published; provisional source preview cleared.",
            **fields)

    def begin_publication(self, jid):
        """Cancellation cannot race a successful candidate publication."""
        with self.lock:
            job = self.jobs[jid]
            if job["_cancel"].is_set():
                raise RuntimeError("generation cancelled before publication")
            job["cancellable"] = False

    def _progress(self, jid, frac, note):
        with self.lock:
            if jid in self.jobs:
                self.jobs[jid]["progress"] = frac
                self.jobs[jid]["note"] = note

    def _update_session_job(self, sid, jid, status, result, error=None):
        fields = {"status": status}
        if result is not None:
            fields["summary"] = summarize(result)
        if error is not None:
            fields["error"] = error
        if status in ("succeeded", "failed", "cancelled"):
            with self.lock:
                current = self.jobs.get(jid)
                if current is not None and "construction" in current:
                    fields.update(public_job(current))
            if "construction" in fields:
                # Durable terminal receipt; a read after server restart
                # returns the recorded facts without rerunning anything.
                name = fields["construction"]["candidate"]
                receipt_dir = os.path.join(self.store.root, "receipts", sid, name)
                os.makedirs(receipt_dir, exist_ok=True)
                receipt = os.path.join(receipt_dir, f"construction-{jid}.json")
                with open(receipt, "w", encoding="utf-8") as f:
                    json.dump(fields, f, indent=2, sort_keys=True)
                    f.write("\n")
                fields["construction_receipt"] = receipt
        entry = self.store.update_job(sid, jid, fields)
        if entry is not None:
            self.store.log("job_" + status, sid, {"job": jid, "op": entry.get("op")})

    def get(self, jid, sid=None):
        with self.lock:
            job = self.jobs.get(jid)
            if job is not None:
                if sid is not None and job["session"] != sid:
                    return None
                return public_job(job)
        if sid is not None:
            session = self.store.load(sid)
            entry = (session or {}).get("jobs", {}).get(jid)
            if entry and "construction" in entry and entry.get("status") in (
                    "succeeded", "failed", "cancelled"):
                return copy.deepcopy(entry)
        return None

    def cancel(self, jid):
        with self.lock:
            job = self.jobs.get(jid)
            if job is None:
                return None
            if job["status"] not in ("queued", "running"):
                return {k: v for k, v in job.items() if not k.startswith("_")}
            if not job.get("cancellable", True):
                return {k: v for k, v in job.items() if not k.startswith("_")}
            job["cancel_requested"] = True
            job["_cancel"].set()
            return {k: v for k, v in job.items() if not k.startswith("_")}


def summarize(result):
    if not isinstance(result, dict):
        return str(result)[:200]
    keys = ("commit", "conclusion", "status", "outcome", "run_id", "tree",
            "decision", "refused")
    return {k: result[k] for k in keys if k in result}


# ------------------------------------------------------------------ ops ---

class Ops:
    def __init__(self, store, jobs):
        self.store = store
        self.jobs = jobs

    # -- paths ------------------------------------------------------
    def clone_dir(self, sid):
        return os.path.join(self.store.root, "repos", sid)

    def cand_dir(self, sid, name):
        return os.path.join(self.store.root, "candidates", sid, name)

    def parent_dir(self, sid, name):
        return os.path.join(self.store.root, "parents", sid, name)

    def receipt_dir(self, sid, name):
        d = os.path.join(self.store.root, "receipts", sid, name)
        os.makedirs(d, exist_ok=True)
        return d

    # -- import -----------------------------------------------------
    def do_import(self, sid, repo, ref):
        check_token(sid, "session")
        if repo not in ALLOWED_REPOS:
            raise ValueError("unsupported repository for this milestone")
        session = self.store.load(sid)
        if session is None:
            raise ValueError("unknown session")
        dest = self.clone_dir(sid)

        def fn(job, cancel, progress):
            progress(0.05, "cloning " + repo)
            if os.path.exists(dest):
                shutil.rmtree(dest)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            url = f"https://github.com/{repo}.git"
            rc, out, err = run(["git", "clone", url, dest], env=git_env(),
                               timeout=300, cancel=cancel)
            if rc != 0 and rc not in ("cancelled", "timeout"):
                raise RuntimeError(f"clone failed: {err[-2000:]}")
            if rc in ("cancelled", "timeout"):
                raise RuntimeError(f"clone {rc}")
            progress(0.4, "resolving " + ref)
            rc, out, err = run(["git", "-C", dest, "rev-parse", ref + "^{commit}"],
                               env=git_env(), timeout=60, cancel=cancel)
            if rc != 0:
                raise RuntimeError(f"ref {ref} unresolvable: {err[-500:]}")
            commit = out.strip()
            # Local main tracks the demo line so explicit commits advance
            # it and pushes move the remote default branch. No other
            # branches are created.
            for args in (["checkout", "-B", "main", commit],
                         ["config", "user.name", "instagrim-dev"],
                         ["config", "user.email",
                          "instagrim-dev@users.noreply.github.com"]):
                rc2, _, err2 = run(["git", "-C", dest] + args,
                                    env=git_env(), timeout=60, cancel=cancel)
                if rc2 != 0:
                    raise RuntimeError(f"git {args[0]} failed: {err2[-300:]}")
            progress(0.6, "verifying blobs at " + commit[:12])
            snap = tree_snapshot(dest)
            # Prove imported bytes equal Git blobs at the resolved commit.
            rc, out, err = run(["git", "-C", dest, "ls-tree", "-r", commit],
                               env=git_env(), timeout=60, cancel=cancel)
            if rc != 0:
                raise RuntimeError("ls-tree failed")
            checked = 0
            for line in out.splitlines():
                parts = line.split(None, 3)
                if len(parts) < 4 or parts[1] != "blob":
                    continue
                kind, blob_path = parts[1], parts[3]
                blob, path = parts[2], blob_path.split("\t")[-1]
                proc = subprocess.Popen(
                    ["git", "-C", dest, "cat-file", "blob", blob],
                    env=git_env(), stdout=subprocess.PIPE)
                blob_bytes, _ = proc.communicate()
                if proc.returncode != 0:
                    raise RuntimeError(f"cat-file {path} failed")
                with open(os.path.join(dest, path), "rb") as f:
                    disk_bytes = f.read()
                if disk_bytes != blob_bytes:
                    raise RuntimeError(f"blob mismatch for {path}")
                checked += 1
            if checked == 0:
                raise RuntimeError("empty tree at resolved commit")
            progress(0.85, "recording import")
            session2 = self.store.load(sid)
            session2["repo"] = {
                "canonical": repo,
                "origin": url,
                "requested_ref": ref,
                "resolved_commit": commit,
                "tree": tree_hash(snap),
                "file_count": len(snap),
                "imported_at": utcnow(),
            }
            self.store.save(session2)
            self.store.log("import", sid, {"repo": repo, "ref": ref,
                                           "commit": commit})
            progress(1.0, "imported " + commit[:12])
            return {"commit": commit, "tree": tree_hash(snap),
                    "file_count": len(snap)}

        job, _ = self.jobs.submit(
            sid, "import", {"repo": repo, "ref": ref}, fn,
            idempotency_key=f"import:{repo}:{ref}")
        return job

    # -- accept (intent only; inline, no model/build/Git) ------------
    def do_accept(self, sid, answer):
        check_token(sid, "session")
        if answer not in ANSWERS:
            raise ValueError("unknown answer")
        # Serialized with job mutations: concurrent accept/job pairs cannot
        # lose state or mix intent with source.
        with self.jobs.session_lock(sid):
            return self._accept_locked(sid, answer)

    def _write_intent(self, root, session):
        """Coordinator-owned manifest, never a generator-edited input."""
        path = os.path.join(root, ".trajectory", "intent.json")
        if not os.path.isdir(os.path.dirname(path)):
            return
        manifest = {
            "schema": "trajectory-intent/1",
            "answer": session["accepted_answer"],
            "question": "If access changes while an export is queued, should "
                        "the original permission stand, or should delivery "
                        "check access again?",
            "constraints": ["tenant isolation", "authorized enqueue",
                            "audit before release", "audit failure blocks release"],
            "history": [{"revision": i["revision"], "answer": i["answer"]}
                        for i in session["intents"]],
        }
        with open(path, "w", encoding="utf-8") as f:
            json.dump(manifest, f, indent=2, sort_keys=True)
            f.write("\n")

    def _accept_locked(self, sid, answer):
        """Caller owns the per-session lock, including a construct job."""
        session = self.store.load(sid)
        if session is None:
            raise ValueError("unknown session")
        if session["accepted_answer"] == answer:
            return {"changed": False, "answer": answer,
                    "intent_revision": len(session["intents"]) - 1}
        revision = len(session["intents"])
        parent = session["intents"][-1]["content_id"] if session["intents"] else None
        content = json.dumps({"answer": answer,
                              "constraints": ["tenant isolation",
                                              "authorized enqueue",
                                              "audit before release",
                                              "audit failure blocks release"]},
                             sort_keys=True)
        session["intents"].append({
            "revision": revision, "answer": answer, "parent": parent,
            "content_id": hashlib.sha256(content.encode()).hexdigest(),
            "accepted_at": utcnow(),
        })
        session["accepted_answer"] = answer
        self._write_intent(self.clone_dir(sid), session)
        self.store.save(session)
        self.store.log("accept", sid, {"answer": answer, "revision": revision})
        return {"changed": True, "answer": answer, "intent_revision": revision}

    # -- generate ----------------------------------------------------
    def _retire_partial(self, sid, name, cdir, pdir, receipts, reason):
        """Move unpublished candidate/parent workspaces under receipts for
        inspection, leaving no half-named candidate behind. Existing
        recorded candidates are never touched: callers only pass
        workspaces created for a name with no candidate record."""
        stamp = time.time_ns()
        dest = os.path.join(receipts, f"partial-{name}-{stamp}")
        os.makedirs(dest, exist_ok=True)
        for label, src in (("candidate", cdir), ("parent", pdir)):
            if os.path.isdir(src):
                shutil.move(src, os.path.join(dest, label))
        with open(os.path.join(dest, "reason.txt"), "w",
                  encoding="utf-8") as f:
            f.write(reason + "\n")
        self.store.log("partial_retired", sid, {"candidate": name,
                                                "at": dest,
                                                "reason": reason})

    def generation_prompt(self, sid, session, name, answer, parent_commit,
                          parent_candidate=None, parent_tree=""):
        cdir = self.cand_dir(sid, name)
        source = (f"immutable candidate {parent_candidate}, tree {parent_tree}"
                  if parent_candidate is not None else
                  f"baseline source workspace, tree {parent_tree}")
        return f"""You are the bounded candidate generator for the Trajectory live demo.

Candidate workspace: {name} at {cdir}.
Pinned input parent: {source}.
Git base anchor: {parent_commit}. An uncommitted candidate parent is identified by its tree, not represented as a new Git commit.
The coordinator copied the parent program and applied the accepted intent manifest before this invocation; do not modify that manifest.
Accepted intent: {answer} ({"capture the authorized permission at enqueue and use that snapshot for delivery" if answer == "queue_time" else "re-check current permission at delivery; a later revocation blocks delivery"}).
Shared constraints (must keep holding): tenant isolation, authorized enqueue, audit before release, audit failure blocks release.

Transformation boundary (mechanical, enforced after you finish):
- You MAY edit exactly these files: queued/queue.go, queued/worker.go.
- You MUST NOT create, delete, or modify any other file, especially: queued/queued_test.go, queued/support_test.go, .trajectory/intent.json, .github/workflows/ci.yml, go.mod, go.sum, cmd/exportdemo/main.go, or any new file outside queued/queue.go and queued/worker.go.
- Do not rewrite tests, workflow, intent, or expected outcomes to pass. Do not add dependencies.

Task: implement the {answer} policy in queued/queue.go + queued/worker.go, with valid Go source:
- queue_time: Mode = "queue_time"; Job carries a PermissionSnapshot bool field capturing the allowed boolean from access.Allowed at Enqueue. Deliver checks !job.PermissionSnapshot instead of querying access. Never retain an Access interface or mutable access object as the snapshot; later revocation must still export with audit+release.
- delivery_time: Mode = "delivery_time"; Job carries no snapshot; Deliver re-checks access.Allowed(job.TenantID, job.UserID) at send (revoked access -> access_revoked, no events).

Read queued/queue.go, queued/worker.go and queued/domain.go as needed, make the minimal policy edit, then finish with a short summary. Do not run go, tests, builds, vet, or formatting commands that create files. The companion owns all compilation and scenario execution in its separate Check operation. Do not create caches, scratch directories, or any extra files. Do not run git, commit, push, or contact the network.
"""

    def do_generate(self, sid, name):
        """Compatibility API: construct under the already accepted intent."""
        return self._submit_generation(sid, name)

    def do_construct(self, sid, name, answer, parent_candidate=None,
                     parent_tree=None):
        """Explicit owner choice + construction in one serialized job.

        Choosing this operation accepts intent; a failed provider does not
        undo that explicit choice, but cannot publish a candidate. A parent
        candidate is copied by immutable tree identity without committing it.
        """
        if answer not in ANSWERS:
            raise ValueError("unknown answer")
        if parent_candidate is not None:
            check_token(parent_candidate, "candidate")
        if parent_tree is not None and (
                not isinstance(parent_tree, str)
                or re.fullmatch(r"[0-9a-f]{64}", parent_tree) is None):
            raise ValueError("parent_tree must be a SHA256 content identity")
        return self._submit_generation(sid, name, answer, parent_candidate,
                                       parent_tree, accept_intent=True)

    def _observe_generation_files(self, jid, cdir, before_files, seen, final=False):
        """Publish observed source bytes only; all live previews are provisional."""
        files, observed_events = [], []
        for rel in sorted(WRITABLE):
            original = before_files.get(rel)
            try:
                after, digest = preview_source(cdir, rel)
            except (OSError, ValueError, UnicodeError):
                if seen.get(rel) != "unavailable":
                    observed_events.append((
                        None, "preview_unavailable",
                        f"Safe bounded preview unavailable for {rel}."))
                seen[rel] = "unavailable"
                continue
            if original is None:
                continue
            before, original_digest = original
            diff = "\n".join(difflib.unified_diff(
                before.splitlines(), after.splitlines(),
                fromfile="parent/" + rel, tofile="candidate/" + rel,
                lineterm=""))
            if len(diff) > PREVIEW_DIFF_LIMIT:
                diff = diff[:PREVIEW_DIFF_LIMIT] + "\n[Diff preview truncated.]"
            files.append({"path": rel, "before": before, "after": after,
                          "diff": diff, "sha256": digest})
            if digest != seen.get(rel, original_digest):
                observed_events.append((
                    "validating" if final else "editing", "file_changed",
                    f"Observed final source update: {rel}." if final else
                    f"Observed source update: {rel} (provisional)."))
            seen[rel] = digest
        # Publish events and their associated bytes as one observation:
        # a reader must never see a new edit event with stale file text.
        with self.jobs.lock:
            self.jobs.construction_update(jid, files=files)
            for stage, kind, message in observed_events:
                self.jobs.construction_update(jid, stage, kind, message)

    def _submit_generation(self, sid, name, requested_answer=None,
                           parent_candidate=None, requested_parent_tree=None,
                           accept_intent=False):
        check_token(sid, "session")
        check_token(name, "candidate")
        session = self.store.load(sid)
        if session is None:
            raise ValueError("unknown session")
        if session["repo"] is None:
            raise ValueError("import a repository first")
        if not accept_intent and session["accepted_answer"] is None:
            raise ValueError("accept an answer first")
        # Candidate identities are immutable: a name is usable exactly
        # once, in any status. A repeat generation — success, failure, or
        # cancellation — must never replace historical evidence, so it is
        # refused before touching any workspace. Retry under a new name.
        existing = session["candidates"].get(name)
        if existing is not None:
            raise ValueError(
                f"candidate {name} already exists with status "
                f"{existing.get('status')}; candidate identities are "
                "immutable, generate under a new name")
        if parent_candidate is not None and parent_candidate not in session["candidates"]:
            raise ValueError("unknown parent candidate")
        requested_answer = requested_answer or session["accepted_answer"]
        expected_revision = len(session["intents"]) - 1
        operation = "construct" if accept_intent else "generate"
        generator = generator_identity()
        construction = {
            "candidate": name, "answer": requested_answer,
            "intent_revision": -1, "source_parent": "",
            "parent_candidate": parent_candidate,
            "parent_tree": requested_parent_tree or "",
            **generator,
            "stage": "queued", "files": [], "events": [],
            "provisional": True, "changed_paths": [],
        }

        def fn(job, cancel, progress):
            # JobManager owns the session lock for this entire function.
            # All authority (choice, revision, parent) is bound here.
            session2 = self.store.load(sid)
            if name in session2["candidates"]:
                raise RuntimeError(
                    f"candidate {name} appeared while queued; refusing to "
                    "replace it")
            cdir = self.cand_dir(sid, name)
            pdir = self.parent_dir(sid, name)
            if os.path.exists(cdir) or os.path.exists(pdir):
                raise RuntimeError(
                    f"workspace for new candidate {name} already exists; "
                    "refusing to replace it")
            self.jobs.construction_update(
                job["job_id"], stage="preparing", kind="preparing",
                message="Validating requested source identity before construction.")
            source_root = self.clone_dir(sid)
            parent_commit = session2["repo"]["resolved_commit"]
            expected_parent_tree = requested_parent_tree
            if parent_candidate is not None:
                parent = session2["candidates"].get(parent_candidate)
                if parent is None:
                    raise RuntimeError("parent candidate no longer exists")
                source_root = self.cand_dir(sid, parent_candidate)
                expected_parent_tree = parent["tree"]
                if requested_parent_tree is not None and requested_parent_tree != expected_parent_tree:
                    raise RuntimeError("requested parent_tree does not match the immutable parent candidate")
                parent_commit = (parent.get("commit") or parent.get("base_git_commit")
                                 or parent["source_parent"])
            if not isinstance(parent_commit, str) or not parent_commit:
                raise RuntimeError("source has no base Git commit identity")
            if not os.path.isdir(source_root):
                raise RuntimeError("source workspace is unavailable")
            source_tree = tree_hash(tree_snapshot(source_root))
            if expected_parent_tree is not None and source_tree != expected_parent_tree:
                raise RuntimeError("parent source differs from its pinned tree identity")
            if cancel.is_set():
                raise RuntimeError("construction cancelled before accepting intent")
            if accept_intent:
                accepted = self._accept_locked(sid, requested_answer)
                session2 = self.store.load(sid)
                self.jobs.construction_update(
                    job["job_id"], kind="intent_accepted",
                    message="Requested owner intent accepted for this construction.")
            else:
                if (session2["accepted_answer"] != requested_answer
                        or len(session2["intents"]) - 1 != expected_revision):
                    raise RuntimeError("accepted intent changed while generation was queued; submit again")
                accepted = {"intent_revision": expected_revision}
            answer = requested_answer
            intent_rev = accepted["intent_revision"]
            # Explicit acceptance may update the baseline clone manifest;
            # it never writes the selected immutable parent candidate.
            source_after_accept = tree_hash(tree_snapshot(source_root))
            self.jobs.construction_update(
                job["job_id"], intent_revision=intent_rev,
                source_parent=parent_commit, parent_tree=source_tree)
            staging = cdir + ".staging-" + job["job_id"]
            receipts = self.receipt_dir(sid, name)
            created_workspaces = False
            published = False
            try:
                shutil.copytree(source_root, staging,
                                ignore=shutil.ignore_patterns(".git"))
                # Pin the current choice into the copied contract, never
                # into the immutable source parent. Both diff baselines
                # carry this coordinator-owned manifest before invocation.
                self._write_intent(staging, session2)
                pinned = pin_protected(staging)
                before_files = {}
                for rel in sorted(WRITABLE):
                    try:
                        before_files[rel] = preview_source(staging, rel)
                    except (OSError, ValueError, UnicodeError):
                        before_files[rel] = None
                created_workspaces = True
                shutil.copytree(staging, pdir)
                shutil.copytree(staging, cdir)
                shutil.rmtree(staging)
                prompt_path = os.path.join(receipts, "generate-prompt.txt")
                with open(prompt_path, "w", encoding="utf-8") as f:
                    f.write(self.generation_prompt(sid, session2, name, answer,
                                                   parent_commit, parent_candidate,
                                                   source_tree))
                import uuid as _uuid
                gen_sid = _uuid.uuid4().hex
                events_path = os.path.join(receipts, f"generator-events-{gen_sid}.jsonl")
                stderr_path = os.path.join(receipts, f"generator-stderr-{gen_sid}.log")
                args, input_bytes = generator_command(generator, cdir, prompt_path, gen_sid)
                seen = {}
                self._observe_generation_files(job["job_id"], cdir, before_files, seen)
                with open(events_path, "wb") as events_f, open(stderr_path, "wb") as err_f:
                    proc = subprocess.Popen(
                        args, cwd=cdir, env=scrub_env_for_generator(),
                        stdin=subprocess.PIPE, stdout=events_f, stderr=err_f,
                        start_new_session=True)
                    self.jobs.construction_update(
                        job["job_id"], stage="invoking", kind="process_started",
                        message=f"{generator['agent']} process started with {generator['provider']}.",
                        generator_session_id=gen_sid if generator["provider"] in ("meta", "baseten") else None)
                    progress(0.0, f"{generator['agent']} generator running")
                    try:
                        proc.stdin.write(input_bytes)
                        proc.stdin.close()
                    except BrokenPipeError:
                        pass
                    deadline = time.monotonic() + GENERATE_TIMEOUT_S
                    try:
                        while True:
                            if cancel.is_set():
                                raise RuntimeError("generation cancelled by operator")
                            self._observe_generation_files(
                                job["job_id"], cdir, before_files, seen)
                            if proc.poll() is not None:
                                break
                            if time.monotonic() > deadline:
                                raise RuntimeError("generation timed out")
                            time.sleep(GENERATION_POLL_INTERVAL_S)
                        rc = proc.wait()
                    except Exception:
                        kill_tree(proc)
                        proc.wait()
                        raise
                self.jobs.construction_update(
                    job["job_id"], stage="validating", kind="process_exited",
                    message=f"Generator process exited {rc}; validating source boundary.")
                progress(0.0, "validating generated source")
                gen_sid = generator_session_id(
                    events_path, gen_sid if generator["provider"] in ("meta", "baseten") else None)
                self.jobs.construction_update(job["job_id"], generator_session_id=gen_sid)
                usage = extract_usage(events_path)
                verdict = verify_boundary(pdir, cdir)
                violations = validate_pinned(cdir, pinned) + [
                    "parent snapshot " + v for v in validate_pinned(pdir, pinned)]
                if tree_hash(tree_snapshot(source_root)) != source_after_accept:
                    violations.append("immutable input source changed during construction")
                if violations:
                    verdict = {"decision": "reject", "changed": verdict["changed"],
                               "violations": verdict.get("violations", []) + violations}
                status, reason = resolve_generation(rc, verdict)
                snap = tree_snapshot(cdir)
                # The process may have written its final bytes between
                # the last live observation and exit. Re-read after exit
                # and validation, and bind every visible hash to the
                # actual candidate snapshot used for the output identity.
                self._observe_generation_files(job["job_id"], cdir,
                                               before_files, seen, final=True)
                final_files = self.jobs.get(job["job_id"])["construction"]["files"]
                if any(snap.get(f["path"]) != f["sha256"] for f in final_files):
                    raise RuntimeError("source changed during final preview binding")
                self.jobs.construction_update(
                    job["job_id"], stage="validating",
                    changed_paths=list(verdict["changed"]))
                record = {
                    "candidate": name, "answer": answer,
                    "intent_revision": intent_rev,
                    "source_parent": parent_commit, "base_git_commit": parent_commit,
                    "parent_candidate": parent_candidate, "parent_tree": source_tree,
                    "tree": tree_hash(snap), "files": len(snap),
                    "changed": verdict["changed"],
                    "generator": {"provider": generator["provider"], "tool": generator["agent"], "model": generator["model"],
                                  "session_id": gen_sid, "exit_code": rc,
                                  "events": events_path, "stderr": stderr_path,
                                  "prompt": prompt_path, "usage": usage},
                    "construction_job_id": job["job_id"],
                    "boundary": verdict, "protected": dict(pinned),
                    "generated_at": utcnow(),
                }
                session3 = self.store.load(sid)
                if status != "succeeded":
                    record["status"] = status
                    session3.setdefault("proposals", []).append(record)
                    self.store.save(session3)
                    self.store.log("generate_" + status, sid, {
                        "candidate": name, "reason": reason, "exit_code": rc,
                        "violations": verdict.get("violations", [])})
                    raise RuntimeError(reason)
                # Last safe cancellation point, before publishing authority.
                self.jobs.begin_publication(job["job_id"])
                record["status"] = "generated"
                session3["candidates"][name] = record
                self.store.save(session3)
                published = True
                self.jobs.construction_update(
                    job["job_id"], kind="boundary_passed",
                    message="Exit and immutable boundary checks passed.",
                    output_tree=record["tree"])
                self.store.log("generate", sid, {"candidate": name, "answer": answer,
                                                 "tree": record["tree"],
                                                 "changed": verdict["changed"]})
                progress(1.0, "generated " + record["tree"][:12])
                return {"candidate": name, "tree": record["tree"],
                        "changed": verdict["changed"], "usage": usage}
            except Exception as e:
                if created_workspaces and not published:
                    self._retire_partial(sid, name, cdir, pdir, receipts, str(e))
                raise
            finally:
                if os.path.isdir(staging):
                    shutil.rmtree(staging)

        params = {"candidate": name, "answer": requested_answer,
                  "parent_candidate": parent_candidate,
                  "parent_tree": requested_parent_tree}
        with self.jobs.lock:
            if accept_intent:
                # Reserve every explicit attempt, including failed and
                # queued attempts, across app/server restarts. Only the
                # identical currently running request may deduplicate.
                latest = self.store.load(sid)
                if name in latest["candidates"]:
                    raise ValueError("candidate identity already exists; choose a fresh name")
                for jid, entry in latest.get("jobs", {}).items():
                    if (entry.get("op") == "construct"
                            and entry.get("params", {}).get("candidate") == name):
                        running = self.jobs.get(jid, sid=sid)
                        if (running is not None
                                and running.get("status") in ("queued", "running")
                                and entry.get("params") == params):
                            return running
                        raise ValueError("construction attempt identity already used; choose a fresh name")
                if any(p.get("candidate") == name
                       for p in latest.get("proposals", [])):
                    raise ValueError("proposal identity already used; choose a fresh name")
            job, _ = self.jobs.submit(
                sid, operation, params, fn,
                idempotency_key=(f"{operation}:{name}:{requested_answer}:"
                                 f"{parent_candidate}:{requested_parent_tree}:{expected_revision}"),
                construction=construction)
            return self.jobs.get(job["job_id"])

    # -- check -------------------------------------------------------
    def do_check(self, sid, name):
        check_token(sid, "session")
        check_token(name, "candidate")
        session = self.store.load(sid)
        if session is None:
            raise ValueError("unknown session")
        cand = session["candidates"].get(name)
        if cand is None:
            raise ValueError("unknown candidate")
        if cand.get("status") not in ("generated", "check_failed"):
            raise ValueError("candidate is not checkable in status "
                             + str(cand.get("status")))
        tree, answer = cand["tree"], cand["answer"]
        intent_rev = cand["intent_revision"]

        def fn(job, cancel, progress):
            cdir = self.cand_dir(sid, name)
            if tree_hash(tree_snapshot(cdir)) != tree:
                raise RuntimeError(
                    "candidate source changed since generation; "
                    "re-generate before checking")
            pinned_intent = intent_identity(cdir)
            if pinned_intent["answer"] != answer:
                raise RuntimeError(
                    "candidate intent manifest declares "
                    f"{pinned_intent['answer']!r} but the candidate was "
                    f"generated under {answer!r}; re-generate under the "
                    "accepted answer")
            # The oracle must be exactly the bytes pinned before
            # generation: a generator that rewrote the tests (in the
            # candidate, the parent snapshot, or both) fails here even
            # when the remaining suite happens to pass.
            pinned = self.store.load(sid)["candidates"][name].get(
                "protected")
            if not pinned:
                raise RuntimeError(
                    "no pinned oracle inventory for this candidate; "
                    "re-generate before checking")
            oracle_violations = validate_pinned(cdir, pinned)
            if oracle_violations:
                raise RuntimeError(
                    "candidate oracle differs from the pre-generation "
                    "pinned inventory: " + "; ".join(oracle_violations))
            go = shutil.which("go") or "/usr/local/go/bin/go"
            steps = [
                ("build", [go, "build", "./..."], 120),
                ("vet", [go, "vet", "./..."], 180),
                ("test", [go, "test", "./...", "-count=1", "-v"], 300),
                ("scenario", [go, "run", "./cmd/exportdemo"], 120),
            ]
            logs = {}
            ok = True
            failing = None
            for i, (label, cmd, timeout) in enumerate(steps):
                progress(0.05 + 0.85 * i / len(steps), "check: " + label)
                env = dict(os.environ)
                env["GOENV"] = "off"
                env["CGO_ENABLED"] = "0"
                rc, out, err = run(cmd, cwd=cdir, env=env, timeout=timeout,
                                   cancel=cancel)
                logs[label] = {"exit": rc, "stdout": out[-6000:],
                               "stderr": err[-6000:]}
                if rc in ("cancelled", "timeout"):
                    raise RuntimeError(f"check {label} {rc}")
                if rc != 0 and ok:
                    ok = False
                    failing = label
            progress(0.95, "recording verification")
            test_names = []
            for line in logs["test"]["stdout"].splitlines():
                if line.startswith("--- PASS:"):
                    test_names.append(line.split("--- PASS:")[1].split()[0])
            # The oracle is nine NAMED checks: a suite that passes with
            # zero (or fewer) named tests proves the oracle was removed,
            # not that the candidate is correct.
            missing_tests = [t for t in EXPECTED_TESTS
                             if t not in test_names]
            if ok and missing_tests:
                ok = False
                failing = "test"
                logs["oracle"] = {
                    "exit": 1,
                    "stdout": ("expected named checks did not run: "
                               + ", ".join(missing_tests)),
                    "stderr": "",
                }
            scenario_status = None
            for line in logs["scenario"]["stdout"].splitlines():
                if line.startswith("process: status="):
                    scenario_status = line.split("status=")[1].split()[0]
            record = {
                "candidate": name, "tree": tree, "answer": answer,
                "intent_revision": intent_rev,
                "intent_manifest": pinned_intent,
                "checker": {"id": CHECKER_ID, "go": go_version(),
                            "oracle_content": checker_content_id(cdir),
                            "expected_tests": list(EXPECTED_TESTS)},
                "steps": logs, "passed": ok, "failing_step": failing,
                "tests_passed": sorted(test_names),
                "scenario_status": scenario_status,
                "checked_at": utcnow(),
            }
            session2 = self.store.load(sid)
            session2["verifications"].append(record)
            session2["candidates"][name]["status"] = (
                "checked" if ok else "check_failed")
            session2["candidates"][name]["last_verification"] = len(
                session2["verifications"]) - 1
            self.store.save(session2)
            self.store.log("check_" + ("pass" if ok else "fail"), sid,
                           {"candidate": name, "tree": tree[:12]})
            progress(1.0, "check " + ("passed" if ok else "FAILED"))
            return {"candidate": name, "passed": ok,
                    "failing_step": failing,
                    "scenario_status": scenario_status,
                    "tests_passed": sorted(test_names)}

        job, _ = self.jobs.submit(
            sid, "check", {"candidate": name}, fn,
            idempotency_key=f"check:{name}:{tree[:12]}")
        return job

    # -- commit (explicit; verifies checked tree == current tree) -----
    def do_commit(self, sid, name, message):
        check_token(sid, "session")
        check_token(name, "candidate")
        session = self.store.load(sid)
        if session is None:
            raise ValueError("unknown session")
        cand = session["candidates"].get(name)
        if cand is None:
            raise ValueError("unknown candidate")
        if cand.get("status") != "checked":
            raise ValueError(
                "commit requires a passing check for the current tree; "
                f"candidate status is {cand.get('status')}")
        tree = cand["tree"]

        def fn(job, cancel, progress):
            cdir = self.cand_dir(sid, name)
            clone = self.clone_dir(sid)
            if tree_hash(tree_snapshot(cdir)) != tree:
                raise RuntimeError(
                    "candidate source changed since the passing check; "
                    "re-check before committing")
            passed = [v for v in self.store.load(sid)["verifications"]
                      if v["candidate"] == name and v["tree"] == tree
                      and v["passed"]]
            if not passed:
                raise RuntimeError("no passing verification for this tree")
            # The clone's manifest must still be the checked one: a later
            # accept (e.g. acceptB after checkA) changes the clone but not
            # the candidate, and committing then would bind A's program to
            # B's intent. Refuse instead.
            clone_intent = intent_identity(clone)
            checked_intent = passed[-1].get("intent_manifest", {})
            if clone_intent["sha256"] != checked_intent.get("sha256"):
                raise RuntimeError(
                    "clone intent manifest changed since the passing "
                    f"check (now {clone_intent['answer']!r}); re-check "
                    "under the accepted answer before committing")
            progress(0.2, "staging candidate tree")
            # Stage the candidate's COMPLETE verified source contract —
            # program, oracle, workflow, and the candidate's own intent
            # manifest — into the session clone, then prove the full
            # staged content equals the checked candidate before Git
            # records anything. Comparing only writable bytes cannot
            # catch an intent/checker mismatch (finding 1).
            cand_snap = tree_snapshot(cdir)
            for entry in os.listdir(clone):
                if entry == ".git":
                    continue
                full = os.path.join(clone, entry)
                if os.path.isdir(full) and not os.path.islink(full):
                    shutil.rmtree(full)
                else:
                    os.remove(full)
            for entry in os.listdir(cdir):
                src = os.path.join(cdir, entry)
                dst = os.path.join(clone, entry)
                if os.path.isdir(src) and not os.path.islink(src):
                    shutil.copytree(src, dst)
                else:
                    shutil.copy2(src, dst)
            if tree_snapshot(clone) != cand_snap:
                raise RuntimeError(
                    "staged clone content differs from the checked "
                    "candidate tree; refusing to commit")
            rc, out, err = run(["git", "-C", clone, "add", "-A"],
                               env=git_env(), timeout=60, cancel=cancel)
            if rc != 0:
                raise RuntimeError(f"git add failed: {err[-500:]}")
            rc, out, err = run(["git", "-C", clone, "status", "--porcelain"],
                               env=git_env(), timeout=60, cancel=cancel)
            changed = [l[3:] for l in out.splitlines() if l.strip()]
            # The candidate may only ever differ from its parent inside
            # the generator boundary plus the coordinator-owned manifest;
            # anything else staged here is foreign to the checked tree.
            allowed = set(WRITABLE) | {".trajectory/intent.json"}
            bad = [p for p in changed if p not in allowed]
            if bad:
                raise RuntimeError(f"unexpected staged paths: {bad}")
            if not changed:
                raise RuntimeError("nothing to commit: tree already committed")
            progress(0.5, "committing")
            rc, out, err = run(
                ["git", "-C", clone, "commit", "-m", message],
                env=git_env(), timeout=60, cancel=cancel)
            if rc != 0:
                raise RuntimeError(f"git commit failed: {err[-1000:]}")
            rc, commit, _ = run(["git", "-C", clone, "rev-parse", "HEAD"],
                                env=git_env(), timeout=60, cancel=cancel)
            commit = commit.strip()
            rc, parent, _ = run(["git", "-C", clone, "rev-parse", "HEAD^"],
                                env=git_env(), timeout=60, cancel=cancel)
            rc, tree_out, _ = run(
                ["git", "-C", clone, "rev-parse", "HEAD^{tree}"],
                env=git_env(), timeout=60, cancel=cancel)
            # Confirm the FULL committed working tree equals the checked
            # candidate tree — every protected byte, not just writable
            # program files. The Git tree id is recorded alongside the
            # content hash so the equality is independently re-checkable.
            if tree_snapshot(clone) != cand_snap:
                raise RuntimeError(
                    "committed working tree differs from the checked "
                    "candidate tree")
            record = {"candidate": name, "commit": commit,
                      "parent": parent.strip(), "tree_git": tree_out.strip(),
                      "tree": tree, "message": message, "ref": "main",
                      "source_parent": cand.get("source_parent"),
                      "committed_at": utcnow(), "push": None}
            session2 = self.store.load(sid)
            session2["commits"].append(record)
            session2["candidates"][name]["status"] = "committed"
            session2["candidates"][name]["commit"] = commit
            # Advance the session clone's resolved commit so a later
            # candidate descends from this one; keep import evidence.
            session2["repo"]["resolved_commit"] = commit
            self.store.save(session2)
            self.store.log("commit", sid, {"candidate": name, "commit": commit})
            progress(1.0, "committed " + commit[:12])
            return {"candidate": name, "commit": commit,
                    "parent": parent.strip()}

        job, _ = self.jobs.submit(
            sid, "commit", {"candidate": name}, fn,
            idempotency_key=f"commit:{name}:{tree[:12]}")
        return job

    # -- push (explicit; separate outcome; retry deduplicates) --------
    def do_push(self, sid, name):
        check_token(sid, "session")
        check_token(name, "candidate")
        session = self.store.load(sid)
        if session is None:
            raise ValueError("unknown session")
        commits = [c for c in session["commits"] if c["candidate"] == name]
        if not commits:
            raise ValueError("no commit for candidate")
        commit = commits[-1]["commit"]

        def fn(job, cancel, progress):
            clone = self.clone_dir(sid)
            progress(0.2, "reading remote head")
            rc, out, err = run(
                ["git", "-C", clone, "ls-remote", "origin",
                 "refs/heads/main"],
                env=git_env(), timeout=120, cancel=cancel)
            if rc != 0:
                raise RuntimeError(f"ls-remote failed: {err[-500:]}")
            remote_head = out.split()[0] if out.split() else None
            if remote_head == commit:
                # Historical already-published commit: report it as
                # present without moving the remote or creating commits.
                outcome = {"pushed": True, "deduplicated": True,
                           "remote_head": remote_head,
                           "note": "remote already at this commit; "
                           "no duplicate commit created"}
                self._record_push(sid, name, commit, outcome)
                session0 = self.store.load(sid)
                if session0["candidates"].get(name):
                    session0["candidates"][name]["status"] = "pushed"
                self.store.save(session0)
                progress(1.0, "already pushed; deduplicated")
                return dict(outcome, candidate=name, commit=commit)
            progress(0.5, "pushing")
            # Push the named commit exactly, never "whatever local main
            # currently is": after B exists, retrying A's push must not
            # move the remote or mislabel B as A.
            rc, out, err = run(
                ["git", "-C", clone, "push", "origin",
                 f"{commit}:refs/heads/main"],
                env=git_env(), timeout=300, cancel=cancel)
            if rc != 0:
                outcome = {"pushed": False, "remote_head": remote_head,
                           "error": err[-1000:]}
                self._record_push(sid, name, commit, outcome)
                raise RuntimeError(f"push failed; commit {commit[:12]} "
                                   f"exists locally: {err[-1000:]}")
            rc, out, _ = run(["git", "-C", clone, "ls-remote", "origin",
                              "refs/heads/main"],
                             env=git_env(), timeout=120, cancel=cancel)
            remote_head = out.split()[0] if out.split() else None
            if remote_head != commit:
                # The push reported success but the remote is not at the
                # selected commit: never label this candidate pushed.
                outcome = {"pushed": False, "deduplicated": False,
                           "remote_head": remote_head,
                           "error": "remote head advanced elsewhere "
                           "during push; candidate not published"}
                self._record_push(sid, name, commit, outcome)
                raise RuntimeError(
                    f"push of {commit[:12]} did not land: remote head is "
                    f"{(remote_head or '?')[:12]}; commit exists locally, "
                    "retry the push explicitly")
            outcome = {"pushed": True, "deduplicated": False,
                       "remote_head": remote_head}
            self._record_push(sid, name, commit, outcome)
            session2 = self.store.load(sid)
            if session2["candidates"].get(name):
                session2["candidates"][name]["status"] = "pushed"
            self.store.save(session2)
            progress(1.0, "pushed " + commit[:12])
            return dict(outcome, candidate=name, commit=commit)

        job, _ = self.jobs.submit(
            sid, "push", {"candidate": name}, fn,
            idempotency_key=f"push:{name}:{commit[:12]}")
        return job

    def _record_push(self, sid, name, commit, outcome):
        session = self.store.load(sid)
        for c in session["commits"]:
            if c["candidate"] == name and c["commit"] == commit:
                c["push"] = dict(outcome, at=utcnow())
        self.store.save(session)
        self.store.log("push", sid, {"candidate": name, "commit": commit,
                                     "pushed": outcome.get("pushed"),
                                     "deduplicated": outcome.get(
                                         "deduplicated", False)})

    # -- observe (exact-head push-run watch; bounded) ------------------
    def do_observe(self, sid, commit, timeout_s=None):
        check_token(sid, "session")
        if not isinstance(commit, str) or not re.match(r"^[0-9a-f]{40}$", commit):
            raise ValueError("invalid commit sha")
        session = self.store.load(sid)
        if session is None:
            raise ValueError("unknown session")
        timeout_s = timeout_s or OBSERVE_DEFAULT_TIMEOUT_S
        timeout_s = max(30, min(1800, int(timeout_s)))

        def fn(job, cancel, progress):
            repo = self.store.load(sid)["repo"]["canonical"]
            deadline = time.time() + timeout_s
            seen = None
            while True:
                if cancel.is_set():
                    raise RuntimeError("observation cancelled by operator")
                rc, out, err = run(
                    ["gh", "api",
                     f"repos/{repo}/actions/runs?head_sha={commit}&event=push",
                     "--jq", ".workflow_runs[] | {id, status, conclusion, "
                             "head_sha, event, html_url, created_at, "
                             "updated_at, run_attempt: .run_attempt, "
                             "jobs_url}"],
                    timeout=60, cancel=cancel)
                if rc != 0:
                    raise RuntimeError(f"runs query failed: {err[-500:]}")
                runs = [json.loads(l) for l in out.splitlines() if l.strip()]
                if runs:
                    seen = sorted(runs, key=lambda r: r["created_at"])[-1]
                    progress(0.1, f"run {seen['id']} {seen['status']}")
                    if seen["status"] == "completed":
                        break
                else:
                    progress(0.05, "waiting for push run to appear")
                if time.time() > deadline:
                    raise RuntimeError(
                        "observe timed out waiting for run completion")
                time.sleep(15)
            # Fetch job conclusions for the exact attempt.
            rc, out, err = run(
                ["gh", "api",
                 f"repos/{repo}/actions/runs/{seen['id']}/attempts/"
                 f"{seen.get('run_attempt', 1)}/jobs",
                 "--jq", "[.jobs[] | {name, conclusion, status}]"],
                timeout=60, cancel=cancel)
            jobs_list = json.loads(out) if rc == 0 and out.strip() else []
            record = {"commit": commit, "run_id": seen["id"],
                      "attempt": seen.get("run_attempt", 1),
                      "event": seen.get("event"), "head_sha": seen["head_sha"],
                      "status": seen["status"],
                      "conclusion": seen["conclusion"],
                      "url": seen["html_url"], "jobs": jobs_list,
                      "observed_at": utcnow()}
            session2 = self.store.load(sid)
            session2["runs"].append(record)
            self.store.save(session2)
            self.store.log("run_observed", sid,
                           {"commit": commit[:12], "run": seen["id"],
                            "conclusion": seen["conclusion"]})
            progress(1.0, f"run {seen['conclusion']}")
            return record

        job, _ = self.jobs.submit(
            sid, "observe", {"commit": commit[:12]}, fn,
            idempotency_key=f"observe:{commit[:12]}")
        return job

    # -- read-only views (method on Ops) ------------------------------
    def diff_text(self, sid, name):
        check_token(sid, "session")
        check_token(name, "candidate")
        session = self.store.load(sid)
        if session is None:
            raise ValueError("unknown session")
        pdir, cdir = self.parent_dir(sid, name), self.cand_dir(sid, name)
        if not os.path.isdir(cdir):
            raise ValueError("unknown candidate")
        out = []
        nfiles = 0
        for rel in sorted(set(tree_snapshot(pdir)) | set(tree_snapshot(cdir))):
            a = os.path.join(pdir, rel)
            b = os.path.join(cdir, rel)
            if os.path.isfile(a) and os.path.isfile(b):
                with open(a, encoding="utf-8") as f:
                    alines = f.readlines()
                with open(b, encoding="utf-8") as f:
                    blines = f.readlines()
                if alines != blines:
                    nfiles += 1
                    out.extend(difflib.unified_diff(
                        alines, blines, lineterm="",
                        fromfile=f"parent/{rel}", tofile=f"candidate/{rel}"))
            elif os.path.isfile(b):
                nfiles += 1
                out.append(f"+++ new file: {rel}")
            else:
                nfiles += 1
                out.append(f"--- removed file: {rel}")
        return {"candidate": name, "diff": "\n".join(out),
                "changed_files": nfiles}


# The nine independent oracle checks the demo service must keep running.
# Pinned as a literal: deriving the expected set from generator-reachable
# files after invocation would let oracle removal hide inside a pass.
EXPECTED_TESTS = (
    "TestOwnerIntent",
    "TestRevokedAccess",
    "TestActiveAccess",
    "TestAuditBeforeRelease",
    "TestAuditFailure",
    "TestTenantIsolation",
    "TestQueueDenial",
    "TestTenantLookup",
    "TestInvalidJob",
)

# The generator may edit exactly WRITABLE and nothing else. The pin is
# the COMPLETE pre-invocation tree inventory (every non-.git file under
# root), captured in coordinator memory BEFORE the generator runs and
# validated AFTER against both the candidate workspace and the sibling
# parent snapshot. A partial path list cannot close this boundary: a
# generator that rewrites an unlisted file identically in both trees
# makes that edit disappear from a post-hoc parent/candidate diff, so
# the pin must cover membership and content of every protected path,
# including additions and deletions (e.g. the scenario command
# cmd/exportdemo/main.go, domain.go, module/config/workflow/test and
# manifest bytes).
PINNED_ORACLE_PATHS = (
    "queued/queued_test.go",
    "queued/support_test.go",
    ".trajectory/intent.json",
    "go.mod",
)


def pin_protected(root):
    """Snapshot sha256 of EVERY file under root (excluding .git).

    Call BEFORE handing a workspace to the generator; the returned dict
    lives in coordinator memory, never in a generator-reachable file.
    The generator runs unsandboxed and can rewrite both the candidate
    workspace and the sibling parent snapshot, so neither on-disk tree
    is authoritative after execution — only this record is."""
    pinned = tree_snapshot(root)
    if not pinned:
        raise RuntimeError("protected baseline tree is empty")
    for rel in PINNED_ORACLE_PATHS:
        if rel not in pinned:
            raise RuntimeError(f"protected baseline file missing: {rel}")
    return pinned


def validate_pinned(root, pinned):
    """Compare a workspace against a pinned inventory. Returns violations.

    Every path outside WRITABLE must match the pin exactly in both
    membership and content: alterations, removals, and additions are
    all violations. WRITABLE paths are skipped — the generator owns
    those bytes. Short legacy pins (the original five oracle paths,
    retained on already-published candidates) validate just their
    listed entries; full pins validate the whole tree."""
    violations = []
    if any(p in pinned for p in WRITABLE):
        current = tree_snapshot(root)
        for rel in sorted(set(pinned) | set(current)):
            if rel in WRITABLE:
                continue
            if rel not in pinned:
                violations.append(f"created file outside boundary: {rel}")
            elif rel not in current:
                violations.append(f"protected file removed: {rel}")
            elif current[rel] != pinned[rel]:
                violations.append(f"protected file altered: {rel}")
        return violations
    for rel, expected in pinned.items():
        full = os.path.join(root, rel)
        if not os.path.isfile(full):
            violations.append(f"protected file removed: {rel}")
        elif sha256_file(full) != expected:
            violations.append(f"protected file altered: {rel}")
    return violations


def checker_content_id(root):
    """Content identity of the checker oracle bytes in a workspace: the
    Go tests that must run, the domain and scenario command they
    exercise, the module, and an optional CI workflow."""
    h = hashlib.sha256()
    for rel in ("queued/queued_test.go", "queued/support_test.go",
                "queued/domain.go", "cmd/exportdemo/main.go",
                ".github/workflows/ci.yml", "go.mod"):
        path = os.path.join(root, rel)
        if rel == ".github/workflows/ci.yml" and not os.path.exists(path):
            h.update(rel.encode() + b"\x00<absent>\x00")
            continue
        with open(path, "rb") as f:
            h.update(rel.encode() + b"\x00" + f.read() + b"\x00")
    return h.hexdigest()


def resolve_generation(exit_code, verdict):
    """Pure decision for a finished generator process: a nonzero exit is
    failed construction even when partial edits sit inside the boundary;
    a boundary violation is rejected; otherwise the proposal is accepted
    for checking. Returns (status, reason)."""
    if exit_code != 0:
        return ("failed",
                f"generator exited {exit_code}; partial proposal retained "
                "for inspection, generate under a new name to retry")
    if verdict["decision"] == "no_change":
        return ("rejected", "generator produced no source changes; generate under a new name to retry")
    if verdict["decision"] != "accept":
        violations = verdict.get("violations", ["unknown"])
        detail = "; ".join(violations[:5])
        if len(violations) > 5:
            detail += f"; {len(violations)} total violations (full boundary receipt retained)"
        return ("rejected", "generator left the mutation boundary: " + detail)
    return ("succeeded", "within boundary; awaiting checks")


def verify_boundary(parent_dir, cand_dir):
    """Mechanical mutation-boundary check: only WRITABLE paths may differ;
    protected paths must be byte-identical; no other files may appear,
    disappear, or change. Returns a verdict dict (pure function of two
    trees, also used by tests)."""
    parent = tree_snapshot(parent_dir)
    cand = tree_snapshot(cand_dir)
    changed = sorted(p for p in set(parent) | set(cand)
                     if parent.get(p) != cand.get(p))
    violations = []
    for p in changed:
        if p in WRITABLE:
            continue
        if p in parent and p not in cand:
            violations.append(f"deleted protected file: {p}")
        elif p not in parent and p not in WRITABLE:
            violations.append(f"created file outside boundary: {p}")
        else:
            violations.append(f"modified protected file: {p}")
    for prefix in PROTECTED_PREFIXES:
        for p in changed:
            if p.startswith(prefix) and p not in WRITABLE:
                note = f"touched protected path: {p}"
                if note not in violations:
                    violations.append(note)
    decision = "accept" if not violations else "reject"
    if decision == "accept" and not changed:
        decision = "no_change"
    return {"decision": decision, "changed": changed,
            "violations": violations}


def extract_usage(events_path):
    """Pull any model/usage accounting the CLI recorded. One CLI
    invocation is never described as one API request; only what the
    receipt actually contains is reported."""
    usage = {"events_bytes": 0, "lines": 0, "usage_fields": {},
             "record_types": {}}
    try:
        size = os.path.getsize(events_path)
        usage["events_bytes"] = size
        with open(events_path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                usage["lines"] += 1
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(obj, dict):
                    rt = obj.get("record_type") or obj.get("type") or "?"
                    usage["record_types"][rt] = \
                        usage["record_types"].get(rt, 0) + 1
                for key in ("usage", "token_usage", "tokens", "model",
                            "cost", "stats"):
                    if isinstance(obj, dict) and key in obj:
                        usage["usage_fields"][key] = obj[key]
    except OSError:
        pass
    return usage


def intent_identity(workdir):
    """Content identity of the coordinator-owned intent manifest inside a
    source tree. The oracle reads this file, so a check/commit binds the
    exact declared answer, not just the program bytes."""
    path = os.path.join(workdir, ".trajectory", "intent.json")
    with open(path, "rb") as f:
        raw = f.read()
    try:
        answer = json.loads(raw.decode("utf-8"))["answer"]
    except (ValueError, KeyError, UnicodeDecodeError) as e:
        raise RuntimeError(f"unreadable intent manifest: {e}")
    if answer not in ANSWERS:
        raise RuntimeError(f"unknown declared answer {answer!r}")
    return {"sha256": hashlib.sha256(raw).hexdigest(), "answer": answer}


def go_version():
    go = shutil.which("go") or "/usr/local/go/bin/go"
    rc, out, _ = run([go, "version"], timeout=30)
    return out.strip() if rc == 0 else "go (version unknown)"


# ----------------------------------------------------------------- http ---

class Handler(BaseHTTPRequestHandler):
    store = None
    jobs = None
    ops = None

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[{utcnow()}] {self.address_string()} {fmt % args}\n")

    def _send(self, code, obj):
        body = json.dumps(obj, indent=2, sort_keys=True).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8") or "{}")

    def do_GET(self):
        try:
            parts = urllib.parse.urlparse(self.path)
            qs = urllib.parse.parse_qs(parts.query)
            segs = [s for s in parts.path.split("/") if s]
            if segs == ["status"]:
                self._send(200, {"service": "trajectory-companion",
                                 "at": utcnow(),
                                 "checker": CHECKER_ID,
                                 "model": generator_identity()["model"],
                                 "provider": generator_identity()["provider"],
                                 "agent": generator_identity()["agent"]})
                return
            if len(segs) == 2 and segs[0] == "sessions":
                check_token(segs[1], "session")
                session = self.store.load(segs[1])
                if session is None:
                    self._send(404, {"error": "unknown session"})
                    return
                self._send(200, session)
                return
            if len(segs) == 4 and segs[0] == "sessions" and segs[2] == "jobs":
                check_token(segs[1], "session")
                check_token(segs[3], "session")
                job = self.jobs.get(segs[3], sid=segs[1])
                if job is None:
                    self._send(404, {"error": "unknown job"})
                    return
                self._send(200, job)
                return
            if len(segs) == 3 and segs[0] == "sessions" and segs[2] == "diff":
                name = qs.get("candidate", [None])[0]
                self._send(200, self.ops.diff_text(segs[1], name))
                return
            if len(segs) == 3 and segs[0] == "sessions" and segs[2] == "source":
                check_token(segs[1], "session")
                name = qs.get("candidate", [None])[0]
                check_token(name, "candidate")
                rel = qs.get("path", [None])[0]
                if not name or not rel or ".." in rel or rel.startswith("/"):
                    self._send(400, {"error": "candidate and path required"})
                    return
                full = os.path.join(self.ops.cand_dir(segs[1], name), rel)
                if not os.path.isfile(full):
                    self._send(404, {"error": "no such file"})
                    return
                with open(full, encoding="utf-8") as f:
                    self._send(200, {"candidate": name, "path": rel,
                                     "text": f.read()})
                return
            self._send(404, {"error": "unknown route"})
        except (ValueError, RuntimeError) as e:
            self._send(400, {"error": str(e)})
        except Exception as e:  # noqa: BLE001
            self._send(500, {"error": f"{type(e).__name__}: {e}"})

    def do_POST(self):
        try:
            # Loopback CSRF mitigation: mutating endpoints require an
            # explicit JSON content type, which unsolicited browser-origin
            # simple requests do not carry (no CORS headers are served).
            ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip()
            if ctype != "application/json":
                self._send(400, {"error": "POST requires application/json"})
                return
            segs = [s for s in urllib.parse.urlparse(self.path).path.split("/")
                    if s]
            body = self._read_json()
            if segs == ["sessions"]:
                self._send(200, self.store.new_session())
                return
            if len(segs) == 3 and segs[0] == "sessions":
                sid, action = segs[1], segs[2]
                if action == "import":
                    self._send(200, public_job(self.ops.do_import(
                        sid, body["repo"], body.get("ref", "main"))))
                    return
                if action == "accept":
                    self._send(200, self.ops.do_accept(sid, body["answer"]))
                    return
                if action == "generate":
                    self._send(200, public_job(
                        self.ops.do_generate(sid, body["candidate"])))
                    return
                if action == "construct":
                    self._send(200, public_job(self.ops.do_construct(
                        sid, body["candidate"], body["answer"],
                        parent_candidate=body.get("parent_candidate"),
                        parent_tree=body.get("parent_tree"))))
                    return
                if action == "check":
                    self._send(200, public_job(
                        self.ops.do_check(sid, body["candidate"])))
                    return
                if action == "commit":
                    self._send(200, public_job(self.ops.do_commit(
                        sid, body["candidate"], body.get("message", ""))))
                    return
                if action == "push":
                    self._send(200, public_job(
                        self.ops.do_push(sid, body["candidate"])))
                    return
                if action == "observe":
                    self._send(200, public_job(self.ops.do_observe(
                        sid, body["commit"],
                        body.get("timeout_s", OBSERVE_DEFAULT_TIMEOUT_S))))
                    return
            if len(segs) == 5 and segs[0] == "sessions" and segs[2] == "jobs" \
                    and segs[4] == "cancel":
                check_token(segs[1], "session")
                check_token(segs[3], "session")
                job = self.jobs.cancel(segs[3])
                if job is None:
                    self._send(404, {"error": "unknown job"})
                    return
                self._send(200, public_job(job))
                return
            self._send(404, {"error": "unknown route"})
        except KeyError as e:
            self._send(400, {"error": f"missing field {e}"})
        except (ValueError, RuntimeError) as e:
            self._send(400, {"error": str(e)})
        except Exception as e:  # noqa: BLE001
            self._send(500, {"error": f"{type(e).__name__}: {e}"})


def public_job(job):
    return copy.deepcopy({k: v for k, v in job.items()
                          if not k.startswith("_")})


def main(argv):
    port = int(os.environ.get("TRAJECTORY_COMPANION_PORT", "8123"))
    if len(argv) > 1:
        port = int(argv[1])
    store = Store(STATE_DIR)
    jobs = JobManager(store)
    Handler.store = store
    Handler.jobs = jobs
    Handler.ops = Ops(store, jobs)
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    sys.stderr.write(f"trajectory-companion on 127.0.0.1:{port} "
                     f"state={STATE_DIR}\n")
    with open(os.path.join(STATE_DIR, "endpoint.txt"), "w",
              encoding="utf-8") as f:
        f.write(f"http://127.0.0.1:{port}\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main(sys.argv)



