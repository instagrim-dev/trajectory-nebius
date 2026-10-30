"""Construction contract tests: local fixture copies and fake processes only.

No Muse/provider, network, Git operations, Go checks, commits, pushes, or CI.
The fake executable exercises the real job/process/file observation path.
"""
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import server

FIXTURE = Path(__file__).resolve().parents[1] / "fixtures/delivery-baseline"


class ConstructionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="trajectory-construct-test-"))
        self.store = server.Store(str(self.tmp / "state"))
        self.jobs = server.JobManager(self.store)
        self.ops = server.Ops(self.store, self.jobs)
        self.poll_patch = mock.patch.object(server, "GENERATION_POLL_INTERVAL_S", .02)
        self.poll_patch.start()
        self.key_patch = mock.patch.dict(os.environ, {"META_API_KEY": "local-test-sentinel"})
        self.key_patch.start()
        self.stub = self.tmp / "fake-generator"
        self.bin_patch = mock.patch.object(server, "MUSE_BIN", str(self.stub))
        self.bin_patch.start()
        self.write_generator(
            "p=Path('queued/worker.go')\n"
            "p.write_text(p.read_text()+'\\n// local fake construction\\n')\n")

    def test_azure_construction_uses_selected_provider_and_real_cli_receipt(self):
        sid = self.seed()
        self.write_generator(
            "p=Path('queued/worker.go')\n"
            "p.write_text(p.read_text()+'\\n// local Azure orchestration test\\n')\n"
            "print(json.dumps({'type':'thread.started','thread_id':'azure-test-thread'}))\n"
            "print(json.dumps({'type':'turn.completed','usage':{'input_tokens':10,'output_tokens':5}}))\n")
        with mock.patch.dict(os.environ, {
            "TRAJECTORY_GENERATOR_PROVIDER": "azure_openai",
            "TRAJECTORY_GENERATOR_MODEL": "test-deployment",
            "TRAJECTORY_CODEX_BIN": str(self.stub),
            "AZURE_OPENAI_BASE_URL": "https://example.openai.azure.com/openai/v1",
            "AZURE_OPENAI_API_KEY": "azure-test-sentinel",
        }):
            job = self.ops.do_construct(sid, "Azure-A", "queue_time")
            done = self.wait_job(job["job_id"])
        self.assertEqual(done["status"], "succeeded", done.get("error"))
        self.assertEqual(done["construction"]["provider"], "azure_openai")
        candidate = self.store.load(sid)["candidates"]["Azure-A"]
        self.assertEqual(candidate["generator"]["tool"], "codex exec")
        self.assertEqual(candidate["generator"]["model"], "test-deployment")
        self.assertEqual(candidate["generator"]["session_id"], "azure-test-thread")
        self.assertEqual(candidate["generator"]["usage"]["usage_fields"]["usage"]["output_tokens"], 5)

    def test_azure_child_inherits_only_selected_provider_credential(self):
        with mock.patch.dict(os.environ, {
            "TRAJECTORY_GENERATOR_PROVIDER": "azure_openai",
            "AZURE_OPENAI_API_KEY": "azure-test-sentinel",
            "META_API_KEY": "unused-meta-key", "GITHUB_TOKEN": "unused-git-key",
        }):
            env = server.scrub_env_for_generator()
        self.assertEqual(env.get("AZURE_OPENAI_API_KEY"), "azure-test-sentinel")
        self.assertNotIn("META_API_KEY", env)
        self.assertNotIn("GITHUB_TOKEN", env)

    def test_baseten_muse_uses_hackathon_model_and_keeps_key_off_command_line(self):
        with mock.patch.dict(os.environ, {
            "TRAJECTORY_GENERATOR_PROVIDER": "baseten",
            "BASETEN_API_KEY": "baseten-test-sentinel",
            "META_API_KEY": "unused-meta-key",
            "GITHUB_TOKEN": "unused-git-key",
        }, clear=True):
            identity = server.generator_identity()
            argv, stdin = server.generator_command(identity, str(self.tmp), "prompt.txt", "test-id")
            child = server.scrub_env_for_generator()
        self.assertEqual(identity["model"], "meta-models/muse-spark-open-1026")
        self.assertEqual(identity["agent"], "muse exec")
        self.assertEqual(json.loads(argv[argv.index("-c") + 1].split("=", 1)[1]), {
            "base_url": "https://inference.baseten.co/v1", "auth": "bearer"})
        self.assertIn("--no-parallel-tool-calls", argv)
        self.assertEqual(argv[argv.index("--reasoning-effort") + 1], "low")
        self.assertEqual(stdin, b"baseten-test-sentinel\n")
        self.assertNotIn("baseten-test-sentinel", argv)
        self.assertNotIn("META_API_KEY", child)
        self.assertNotIn("GITHUB_TOKEN", child)

    def test_large_boundary_failure_has_bounded_native_summary(self):
        violations = ["created file outside boundary: .tmp/gocache/" + str(i) for i in range(1000)]
        status, reason = server.resolve_generation(0, {"decision": "reject", "violations": violations})
        self.assertEqual(status, "rejected")
        self.assertLess(len(reason), 1200)
        self.assertIn("1000", reason)
        self.assertEqual(len(violations), 1000)

    def test_no_source_change_is_reported_distinctly_from_boundary_violation(self):
        status, reason = server.resolve_generation(0, {"decision": "no_change", "violations": []})
        self.assertEqual(status, "rejected")
        self.assertIn("no source changes", reason)

    def test_azure_does_not_expose_invented_session_while_running(self):
        sid = self.seed()
        self.write_generator(
            "print(json.dumps({'type':'thread.started','thread_id':'actual-thread'}), flush=True)\n"
            "time.sleep(.8)\n"
            "p=Path('queued/worker.go')\n"
            "p.write_text(p.read_text()+'\\n// Azure test\\n')\n")
        with mock.patch.dict(os.environ, {
            "TRAJECTORY_GENERATOR_PROVIDER": "azure_openai", "TRAJECTORY_GENERATOR_MODEL": "test-deployment",
            "TRAJECTORY_CODEX_BIN": str(self.stub), "AZURE_OPENAI_BASE_URL": "https://example.openai.azure.com/openai/v1",
            "AZURE_OPENAI_API_KEY": "azure-test-sentinel",
        }):
            job = self.ops.do_construct(sid, "Azure-live", "queue_time")
            live = self.until(lambda: (j if (j := self.jobs.get(job["job_id"]))["construction"]["stage"] == "invoking" else None))
            self.assertIn(live["construction"].get("generator_session_id"), (None, "actual-thread"))
            done = self.wait_job(job["job_id"])
            self.assertEqual(done["construction"]["generator_session_id"], "actual-thread")

    def tearDown(self):
        for jid, job in list(self.jobs.jobs.items()):
            if job["status"] in ("queued", "running"):
                self.jobs.cancel(jid)
        for jid, job in list(self.jobs.jobs.items()):
            if job["status"] in ("queued", "running"):
                self.wait_job(jid)
        self.bin_patch.stop()
        self.key_patch.stop()
        self.poll_patch.stop()
        self.store.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_generator(self, body):
        self.stub.write_text(
            "#!/usr/bin/env python3\nfrom pathlib import Path\n"
            "import json,sys,time,os\nsys.stdin.readline()\n" + body)
        self.stub.chmod(0o700)

    def seed(self, answer="delivery_time"):
        sid = self.store.new_session()["session_id"]
        clone = Path(self.ops.clone_dir(sid))
        clone.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(FIXTURE, clone)
        s = self.store.load(sid)
        s["repo"] = {"canonical": "local/test", "resolved_commit": "b" * 40,
                     "tree": server.tree_hash(server.tree_snapshot(clone))}
        self.store.save(s)
        self.ops.do_accept(sid, answer)
        return sid

    def inject_parent(self, sid, name, marker):
        path = Path(self.ops.cand_dir(sid, name))
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(self.ops.clone_dir(sid), path)
        with (path / "queued/worker.go").open("a") as f:
            f.write("\n// " + marker + "\n")
        s = self.store.load(sid)
        digest = server.tree_hash(server.tree_snapshot(path))
        s["candidates"][name] = {
            "candidate": name, "answer": s["accepted_answer"],
            "intent_revision": len(s["intents"]) - 1,
            "source_parent": "b" * 40, "tree": digest,
            "status": "generated", "changed": ["queued/worker.go"],
            "protected": server.pin_protected(self.ops.clone_dir(sid)),
        }
        self.store.save(s)
        return digest

    def until(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = predicate()
            if result:
                return result
            time.sleep(.01)
        self.fail("timed out waiting for local test condition")

    def wait_job(self, jid):
        done = self.until(lambda: (j if (j := self.jobs.get(jid))["status"]
                                  in ("succeeded", "failed", "cancelled") else None))
        # Terminal authority must be durably readable, not merely a live dict.
        self.until(lambda: self.store.load(done["session"])["jobs"][jid].get("status")
                   == done["status"])
        return done

    def test_atomic_choice_and_parent_are_pinned_while_later_accept_waits(self):
        sid = self.seed()
        release = self.tmp / "release"
        self.write_generator(
            "answer=json.loads(Path('.trajectory/intent.json').read_text())['answer']\n"
            "p=Path('queued/worker.go')\n"
            "p.write_text(p.read_text()+'\\n// chosen '+answer+'\\n')\n"
            f"while not Path({str(release)!r}).exists(): time.sleep(.02)\n")
        job = self.ops.do_construct(sid, "A-new", "queue_time")
        self.until(lambda: self.jobs.get(job["job_id"])["construction"]["stage"] == "editing")
        later_done = threading.Event()
        t = threading.Thread(target=lambda: (self.ops.do_accept(sid, "delivery_time"),
                                            later_done.set()))
        t.start()
        time.sleep(.05)
        self.assertFalse(later_done.is_set())
        observed = self.jobs.get(job["job_id"])["construction"]
        self.assertEqual(observed["answer"], "queue_time")
        self.assertEqual(observed["intent_revision"], 1)
        self.assertNotIn("A-new", self.store.load(sid)["candidates"])
        release.touch()
        done = self.wait_job(job["job_id"])
        t.join(2)
        self.assertEqual(done["status"], "succeeded")
        s = self.store.load(sid)
        self.assertEqual(s["accepted_answer"], "delivery_time")
        self.assertEqual(s["candidates"]["A-new"]["answer"], "queue_time")
        self.assertEqual(s["candidates"]["A-new"]["intent_revision"], 1)
        self.assertIn("chosen queue_time", Path(self.ops.cand_dir(sid, "A-new"),
                                               "queued/worker.go").read_text())

    def test_uncommitted_candidate_parent_preserves_saved_a_and_b(self):
        sid = self.seed("queue_time")
        a_tree = self.inject_parent(sid, "A", "saved A source")
        b_tree = self.inject_parent(sid, "B", "saved B source")
        saved = copy.deepcopy(self.store.load(sid)["candidates"])
        job = self.ops.do_construct(sid, "B-new", "delivery_time", "A", a_tree)
        done = self.wait_job(job["job_id"])
        self.assertEqual(done["status"], "succeeded", done.get("error"))
        s = self.store.load(sid)
        candidate = s["candidates"]["B-new"]
        self.assertEqual(candidate["parent_candidate"], "A")
        self.assertEqual(candidate["parent_tree"], a_tree)
        self.assertEqual(candidate["source_parent"], "b" * 40)
        self.assertEqual(candidate["base_git_commit"], "b" * 40)
        self.assertEqual(s["commits"], [])
        self.assertEqual(s["repo"]["resolved_commit"], "b" * 40)
        self.assertEqual(s["candidates"]["A"], saved["A"])
        self.assertEqual(s["candidates"]["B"], saved["B"])
        self.assertEqual(server.tree_hash(server.tree_snapshot(self.ops.cand_dir(sid, "A"))), a_tree)
        self.assertEqual(server.tree_hash(server.tree_snapshot(self.ops.cand_dir(sid, "B"))), b_tree)
        root = Path(self.ops.cand_dir(sid, "B-new"))
        self.assertIn("saved A source", (root / "queued/worker.go").read_text())
        self.assertEqual(json.loads((root / ".trajectory/intent.json").read_text())["answer"], "delivery_time")
        self.assertEqual(candidate["generator"]["provider"], "meta")
        prompt = Path(candidate["generator"]["prompt"]).read_text()
        self.assertIn("immutable candidate A, tree " + a_tree, prompt)
        self.assertIn("Git base anchor: " + "b" * 40, prompt)
        self.assertNotIn("a copy of commit", prompt)
        self.assertEqual(candidate["status"], "generated")
        self.assertFalse(done["construction"]["provisional"])

    def test_wrong_parent_hash_fails_before_acceptance_or_process(self):
        sid = self.seed()
        self.inject_parent(sid, "A", "saved A")
        before = self.store.load(sid)["intents"]
        with mock.patch.object(server.subprocess, "Popen") as popen:
            done = self.wait_job(self.ops.do_construct(
                sid, "wrong-parent", "queue_time", "A", "0" * 64)["job_id"])
        popen.assert_not_called()
        self.assertEqual(done["status"], "failed")
        self.assertIn("parent_tree", done["error"])
        self.assertEqual(self.store.load(sid)["intents"], before)
        self.assertEqual(done["construction"]["files"], [])

    def test_live_preview_is_observed_provisional_and_excludes_raw_logs(self):
        sid = self.seed()
        release = self.tmp / "release"
        self.write_generator(
            "print('PRIVATE_REASONING_AND_LOG_SENTINEL',flush=True)\n"
            "p=Path('queued/worker.go')\n"
            "p.write_text(p.read_text()+'\\n// observed edit\\n')\n"
            f"while not Path({str(release)!r}).exists(): time.sleep(.02)\n")
        job = self.ops.do_construct(sid, "preview", "queue_time")
        def preview_ready():
            j = self.jobs.get(job["job_id"])
            return j if any(e["kind"] == "file_changed"
                            for e in j["construction"]["events"]) else None
        current = self.until(preview_ready)
        self.assertEqual(current["status"], "running")
        self.assertEqual(current["progress"], 0.0)
        self.assertTrue(current["construction"]["provisional"])
        self.assertNotIn("preview", self.store.load(sid)["candidates"])
        f = next(f for f in current["construction"]["files"] if f["path"] == "queued/worker.go")
        self.assertIn("observed edit", f["after"])
        self.assertNotIn("observed edit", f["before"])
        self.assertIn("+// observed edit", f["diff"])
        self.assertEqual(f["sha256"], hashlib.sha256(f["after"].encode()).hexdigest())
        self.assertNotIn("PRIVATE_REASONING", json.dumps(current))
        self.assertNotIn("local-test-sentinel", json.dumps(current))
        self.assertTrue(all(isinstance(e["id"], str) for e in current["construction"]["events"]))
        f["after"] = "tampered client copy"
        self.assertNotIn("tampered", json.dumps(self.jobs.get(job["job_id"])))
        release.touch()
        self.assertEqual(self.wait_job(job["job_id"])["status"], "succeeded")

    def test_failed_attempt_receipt_survives_restart_and_name_cannot_be_reused(self):
        sid = self.seed()
        self.write_generator("p=Path('queued/worker.go')\np.write_text(p.read_text()+'\\n// partial\\n')\nsys.exit(7)\n")
        job = self.ops.do_construct(sid, "A-2", "queue_time")
        done = self.wait_job(job["job_id"])
        self.assertEqual(done["status"], "failed")
        self.assertIn("exited 7", done["error"])
        self.assertEqual(done["construction"]["files"], [])
        self.assertFalse(done["construction"]["provisional"])
        self.assertNotIn("output_tree", done["construction"])
        s = self.store.load(sid)
        self.assertNotIn("A-2", s["candidates"])
        self.assertEqual(s["accepted_answer"], "queue_time")
        self.assertEqual(s["jobs"][job["job_id"]]["params"]["candidate"], "A-2")
        self.assertTrue(Path(s["jobs"][job["job_id"]]["construction_receipt"]).is_file())
        restarted = server.JobManager(self.store)
        resumed_ops = server.Ops(self.store, restarted)
        receipt = restarted.get(job["job_id"], sid=sid)
        self.assertEqual(receipt["construction"], done["construction"])
        self.assertIsNone(restarted.get(job["job_id"], sid="0" * 12))
        before = Path(self.store.path(sid)).read_bytes()
        with self.assertRaisesRegex(ValueError, "identity already used"):
            resumed_ops.do_construct(sid, "A-2", "queue_time")
        self.assertEqual(Path(self.store.path(sid)).read_bytes(), before)

    def test_inflight_identical_construct_deduplicates_and_reserves_queued_name(self):
        sid = self.seed()
        lock = self.jobs.session_lock(sid)
        lock.acquire()
        try:
            first = self.ops.do_construct(sid, "reserved", "queue_time")
            second = self.ops.do_construct(sid, "reserved", "queue_time")
            self.assertEqual(first["job_id"], second["job_id"])
            entry = self.store.load(sid)["jobs"][first["job_id"]]
            self.assertEqual(entry["construction"]["candidate"], "reserved")
            with self.assertRaises(ValueError):
                self.ops.do_construct(sid, "reserved", "delivery_time")
            self.jobs.cancel(first["job_id"])
        finally:
            lock.release()
        self.assertEqual(self.wait_job(first["job_id"])["status"], "cancelled")
        self.assertEqual(self.store.load(sid)["accepted_answer"], "delivery_time")

    def test_cancellation_clears_preview_and_publishes_no_candidate(self):
        sid = self.seed()
        self.write_generator("p=Path('queued/worker.go')\np.write_text(p.read_text()+'\\n// partial\\n')\ntime.sleep(4)\n")
        job = self.ops.do_construct(sid, "cancel", "queue_time")
        self.until(lambda: self.jobs.get(job["job_id"])["construction"]["stage"] == "editing")
        self.jobs.cancel(job["job_id"])
        done = self.wait_job(job["job_id"])
        self.assertEqual(done["status"], "cancelled")
        self.assertEqual(done["construction"]["files"], [])
        self.assertNotIn("cancel", self.store.load(sid)["candidates"])
        self.assertFalse(Path(self.ops.cand_dir(sid, "cancel")).exists())

    def test_protected_rewrite_of_candidate_and_parent_still_rejected(self):
        sid = self.seed()
        pdir = self.ops.parent_dir(sid, "boundary")
        self.write_generator(
            "Path('cmd/exportdemo/main.go').write_text('rewritten oracle')\n"
            f"Path({pdir!r},'cmd/exportdemo/main.go').write_text('rewritten oracle')\n"
            "p=Path('queued/worker.go')\np.write_text(p.read_text()+'\\n// allowed-looking edit\\n')\n")
        done = self.wait_job(self.ops.do_construct(sid, "boundary", "queue_time")["job_id"])
        self.assertEqual(done["status"], "failed")
        s = self.store.load(sid)
        self.assertNotIn("boundary", s["candidates"])
        self.assertEqual(s["proposals"][-1]["status"], "rejected")
        self.assertTrue(any("cmd/exportdemo" in x for x in s["proposals"][-1]["boundary"]["violations"]))

    def test_preview_special_files_and_symlinks_do_not_block_or_escape(self):
        sid = self.seed()
        root = Path(self.ops.clone_dir(sid))
        p = root / "queued/worker.go"
        p.unlink()
        os.mkfifo(p)
        started = time.monotonic()
        with self.assertRaises(ValueError):
            server.preview_source(str(root), "queued/worker.go")
        self.assertLess(time.monotonic() - started, .3)
        with self.assertRaises(ValueError):
            server.tree_snapshot(str(root))
        p.unlink()
        secret = self.tmp / "not-source"
        secret.write_text("must not read this")
        p.symlink_to(secret)
        with self.assertRaises(OSError):
            server.preview_source(str(root), "queued/worker.go")
        with self.assertRaises(ValueError):
            server.preview_source(str(root), "../not-source")

    def test_oversize_revision_removes_stale_preview(self):
        sid = self.seed()
        oversize = self.tmp / "oversize"
        release = self.tmp / "release"
        self.write_generator(
            "p=Path('queued/worker.go')\np.write_text(p.read_text()+'\\n// initial edit\\n')\n"
            f"while not Path({str(oversize)!r}).exists(): time.sleep(.02)\n"
            f"p.write_text('x'*{server.PREVIEW_FILE_LIMIT + 1})\n"
            f"while not Path({str(release)!r}).exists(): time.sleep(.02)\n")
        job = self.ops.do_construct(sid, "oversize", "queue_time")
        self.until(lambda: self.jobs.get(job["job_id"])["construction"]["stage"] == "editing")
        oversize.touch()
        self.until(lambda: any(e["kind"] == "preview_unavailable"
                               for e in self.jobs.get(job["job_id"])["construction"]["events"]))
        self.assertFalse(any(f["path"] == "queued/worker.go" for f in
                             self.jobs.get(job["job_id"])["construction"]["files"]))
        self.jobs.cancel(job["job_id"])
        release.touch()
        self.assertEqual(self.wait_job(job["job_id"])["status"], "cancelled")

    def test_legacy_generate_api_keeps_intent_and_returns_generated_candidate(self):
        sid = self.seed("queue_time")
        before = self.store.load(sid)["intents"]
        done = self.wait_job(self.ops.do_generate(sid, "legacy")["job_id"])
        self.assertEqual(done["status"], "succeeded", done.get("error"))
        self.assertEqual(done["op"], "generate")
        self.assertEqual(self.store.load(sid)["intents"], before)
        self.assertEqual(done["result"]["candidate"], "legacy")
        self.assertEqual(self.store.load(sid)["candidates"]["legacy"]["status"], "generated")

    def test_final_write_after_last_running_observation_is_hash_bound(self):
        sid = self.seed()
        class FinalWriteOnPoll:
            def __init__(self, args, cwd=None, **kwargs):
                self.root = Path(cwd)
                self.stdin = io.BytesIO()
                self.returncode = None
            def poll(self):
                if self.returncode is None:
                    p = self.root / "queued/worker.go"
                    p.write_text(p.read_text() + "\n// last write at process exit\n")
                    self.returncode = 0
                return self.returncode
            def wait(self):
                return self.returncode
        with mock.patch.object(server.subprocess, "Popen", FinalWriteOnPoll):
            done = self.wait_job(self.ops.do_construct(sid, "last-write", "queue_time")["job_id"])
        self.assertEqual(done["status"], "succeeded", done.get("error"))
        file = next(f for f in done["construction"]["files"] if f["path"] == "queued/worker.go")
        self.assertIn("last write at process exit", file["after"])
        snap = server.tree_snapshot(self.ops.cand_dir(sid, "last-write"))
        self.assertEqual(file["sha256"], snap[file["path"]])
        self.assertEqual(done["construction"]["output_tree"], server.tree_hash(snap))
        self.assertEqual(done["construction"]["changed_paths"], ["queued/worker.go"])

    def test_unpreviewable_final_edit_still_reports_actual_changed_paths(self):
        sid = self.seed()
        self.write_generator(f"Path('queued/worker.go').write_text('x'*{server.PREVIEW_FILE_LIMIT + 1})\n")
        done = self.wait_job(self.ops.do_construct(sid, "large-final", "queue_time")["job_id"])
        self.assertEqual(done["status"], "succeeded", done.get("error"))
        self.assertEqual(done["construction"]["changed_paths"], ["queued/worker.go"])
        self.assertFalse(any(f["path"] == "queued/worker.go" for f in done["construction"]["files"]))

    def test_legacy_queued_generate_refuses_changed_intent(self):
        sid = self.seed()
        lock = self.jobs.session_lock(sid)
        lock.acquire()
        try:
            job = self.ops.do_generate(sid, "stale")
            self.ops._accept_locked(sid, "queue_time")
        finally:
            lock.release()
        done = self.wait_job(job["job_id"])
        self.assertEqual(done["status"], "failed")
        self.assertIn("intent changed", done["error"])
        self.assertNotIn("stale", self.store.load(sid)["candidates"])

    def test_http_construct_and_saved_readback_do_not_mutate_authority(self):
        sid = self.seed()
        handler = object.__new__(server.Handler)
        handler.store, handler.jobs, handler.ops = self.store, self.jobs, self.ops
        handler.path = f"/sessions/{sid}/construct"
        handler.headers = {"Content-Type": "application/json"}
        handler._read_json = lambda: {"candidate": "http", "answer": "queue_time"}
        replies = []
        handler._send = lambda code, obj: replies.append((code, obj))
        handler.do_POST()
        self.assertEqual(replies[-1][0], 200)
        self.assertEqual(replies[-1][1]["construction"]["candidate"], "http")
        jid = replies[-1][1]["job_id"]
        self.assertEqual(self.wait_job(jid)["status"], "succeeded")
        handler.jobs = server.JobManager(self.store)
        before = Path(self.store.path(sid)).read_bytes()
        candidate_before = server.tree_snapshot(self.ops.cand_dir(sid, "http"))
        for suffix in ["", f"/jobs/{jid}", "/diff?candidate=http",
                       "/source?candidate=http&path=queued%2Fworker.go"]:
            handler.path = f"/sessions/{sid}" + suffix
            handler.do_GET()
            self.assertEqual(replies[-1][0], 200)
        self.assertEqual(Path(self.store.path(sid)).read_bytes(), before)
        self.assertEqual(server.tree_snapshot(self.ops.cand_dir(sid, "http")), candidate_before)

    def test_stale_session_save_cannot_erase_a_reserved_attempt(self):
        sid = self.seed()
        stale = self.store.load(sid)
        lock = self.jobs.session_lock(sid)
        lock.acquire()
        try:
            job = self.ops.do_construct(sid, "durable", "queue_time")
            self.store.save(stale)
            self.assertIn(job["job_id"], self.store.load(sid)["jobs"])
            self.jobs.cancel(job["job_id"])
        finally:
            lock.release()
        self.wait_job(job["job_id"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
