#!/usr/bin/env python3
"""Meaningful boundary/operation tests for the trajectory companion.

All tests run against scratch state (tempfile dirs) and scratch git
remotes (local bare repos) — nothing touches GitHub or the demo repo.
The real toolchain (git, go) and the real JobManager/Ops code paths are
exercised; failures below are genuine observed failures, not mocks.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import server
from server import JobManager, Ops, Store, tree_hash, tree_snapshot, verify_boundary

# Pinned delivery-time seed fixture inside this product. Tests must not
# read the mutable demo checkout: its policy advances (queue-time A,
# workflow updates) while these tests declare delivery-time intent,
# which previously produced three fixture-drift failures. The fixture
# bytes equal baseline 5e58f25; see ../fixtures/delivery-baseline.json.
DEMO = os.path.join(os.path.dirname(__file__), "..", "fixtures",
                    "delivery-baseline")


def sh(*args, cwd=None, env=None):
    e = dict(os.environ)
    e["GIT_TERMINAL_PROMPT"] = "0"
    e["GIT_CONFIG_COUNT"] = "1"
    e["GIT_CONFIG_KEY_0"] = "credential.helper"
    e["GIT_CONFIG_VALUE_0"] = ""
    if env:
        e.update(env)
    p = subprocess.run(args, cwd=cwd, env=e, capture_output=True, text=True,
                       timeout=120)
    return p


def await_job(jobs, jid, timeout=180):
    deadline = time.time() + timeout
    while time.time() < deadline:
        job = jobs.get(jid)
        if job["status"] in ("succeeded", "failed", "cancelled"):
            return job
        time.sleep(0.2)
    raise TimeoutError(f"job {jid} still {jobs.get(jid)['status']}")


class CompanionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="companion-test-")
        self.store = Store(os.path.join(self.tmp, "state"))
        self.jobs = JobManager(self.store)
        self.ops = Ops(self.store, self.jobs)
        # Scratch origin (local bare repo): pushes here never reach GitHub.
        self.origin = os.path.join(self.tmp, "origin.git")
        sh("git", "init", "--bare", "-b", "main", self.origin)
        self.assertEqual(sh("git", "--version").returncode, 0)

    def tearDown(self):
        self.store.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    # -- helpers ------------------------------------------------------
    def seed_session(self, answer="delivery_time"):
        """Session whose clone is a real git repo seeded from the demo tree,
        pushed to the scratch origin."""
        session = self.store.new_session()
        sid = session["session_id"]
        clone = self.ops.clone_dir(sid)
        os.makedirs(os.path.dirname(clone), exist_ok=True)
        sh("git", "clone", self.origin, clone)
        for rel in ("go.mod", "queued/domain.go", "queued/queue.go",
                    "queued/worker.go", "queued/queued_test.go",
                    "queued/support_test.go", "cmd/exportdemo/main.go",
                    ".github/workflows/ci.yml", ".trajectory/intent.json",
                    "README.md"):
            src = os.path.join(DEMO, rel)
            dst = os.path.join(clone, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)
        sh("git", "-C", clone, "config", "user.name", "test")
        sh("git", "-C", clone, "config", "user.email", "test@example.com")
        sh("git", "-C", clone, "add", "-A")
        sh("git", "-C", clone, "commit", "-m", "seed")
        sh("git", "-C", clone, "push", "origin", "main")
        commit = sh("git", "-C", clone, "rev-parse", "HEAD").stdout.strip()
        session = self.store.load(sid)
        session["repo"] = {"canonical": "local/scratch", "origin": self.origin,
                           "requested_ref": "main", "resolved_commit": commit,
                           "tree": tree_hash(tree_snapshot(clone)),
                           "file_count": len(tree_snapshot(clone)),
                           "imported_at": server.utcnow()}
        self.store.save(session)
        self.ops.do_accept(sid, answer)
        return sid, commit

    def inject_candidate(self, sid, name, mutate=None):
        """Lay out parent + candidate workspaces like do_generate would,
        optionally mutating the candidate first. Returns (tree, snap).

        The pinned oracle inventory is captured from the pristine clone
        BEFORE the mutation, mirroring the pre-invocation pin: a test
        mutation that rewrites the oracle must be caught, not absorbed."""
        cdir, pdir = self.ops.cand_dir(sid, name), self.ops.parent_dir(sid, name)
        for d in (cdir, pdir):
            shutil.copytree(self.ops.clone_dir(sid), d,
                            ignore=shutil.ignore_patterns(".git"))
        pinned = server.pin_protected(self.ops.clone_dir(sid))
        if mutate:
            mutate(cdir)
        snap = tree_snapshot(cdir)
        session = self.store.load(sid)
        session["candidates"][name] = {
            "candidate": name, "answer": session["accepted_answer"],
            "intent_revision": len(session["intents"]) - 1,
            "source_parent": session["repo"]["resolved_commit"],
            "tree": tree_hash(snap), "files": len(snap),
            "changed": [], "status": "generated",
            "protected": dict(pinned)}
        self.store.save(session)
        return tree_hash(snap)

    # -- tests ---------------------------------------------------------
    def test_accept_changes_intent_only(self):
        session = self.store.new_session()
        sid = session["session_id"]
        r1 = self.ops.do_accept(sid, "queue_time")
        self.assertTrue(r1["changed"])
        self.assertEqual(r1["intent_revision"], 0)
        # Accepting the same answer again changes nothing.
        r2 = self.ops.do_accept(sid, "queue_time")
        self.assertFalse(r2["changed"])
        self.assertEqual(r2["intent_revision"], 0)
        session = self.store.load(sid)
        self.assertEqual(len(session["intents"]), 1)
        self.assertEqual(session["intents"][0]["answer"], "queue_time")
        with self.assertRaises(ValueError):
            self.ops.do_accept(sid, "yesterday")

    def test_boundary_accepts_writable_only(self):
        sid, _ = self.seed_session()
        cdir, pdir = self.ops.cand_dir(sid, "A"), self.ops.parent_dir(sid, "A")
        shutil.copytree(self.ops.clone_dir(sid), pdir,
                        ignore=shutil.ignore_patterns(".git"))
        shutil.copytree(self.ops.clone_dir(sid), cdir,
                        ignore=shutil.ignore_patterns(".git"))
        self.assertEqual(verify_boundary(pdir, cdir)["decision"], "no_change")
        with open(os.path.join(cdir, "queued", "queue.go"), "a") as f:
            f.write("\n// candidate note\n")
        v = verify_boundary(pdir, cdir)
        self.assertEqual(v["decision"], "accept")
        self.assertEqual(v["changed"], ["queued/queue.go"])

    def test_generator_editing_protected_files_is_rejected(self):
        """A rogue generator editing the oracle is caught mechanically and
        its proposal preserved for inspection."""
        sid, _ = self.seed_session()
        cdir, pdir = self.ops.cand_dir(sid, "R"), self.ops.parent_dir(sid, "R")
        shutil.copytree(self.ops.clone_dir(sid), pdir,
                        ignore=shutil.ignore_patterns(".git"))
        shutil.copytree(self.ops.clone_dir(sid), cdir,
                        ignore=shutil.ignore_patterns(".git"))
        # Rogue edit: weaken the oracle instead of the program.
        test_path = os.path.join(cdir, "queued", "queued_test.go")
        with open(test_path, "a") as f:
            f.write("\n// rogue: always pass\n")
        verdict = verify_boundary(pdir, cdir)
        self.assertEqual(verdict["decision"], "reject")
        self.assertTrue(any("queued_test.go" in v
                            for v in verdict["violations"]),
                        verdict["violations"])
        # Proposal preserved, not silently dropped.
        self.assertTrue(os.path.isfile(test_path))

    def test_new_file_outside_boundary_rejected(self):
        sid, _ = self.seed_session()
        cdir, pdir = self.ops.cand_dir(sid, "N"), self.ops.parent_dir(sid, "N")
        shutil.copytree(self.ops.clone_dir(sid), pdir,
                        ignore=shutil.ignore_patterns(".git"))
        shutil.copytree(self.ops.clone_dir(sid), cdir,
                        ignore=shutil.ignore_patterns(".git"))
        with open(os.path.join(cdir, "queued", "backdoor.go"), "w") as f:
            f.write("package queued\n")
        verdict = verify_boundary(pdir, cdir)
        self.assertEqual(verdict["decision"], "reject")

    def test_check_passes_on_good_tree(self):
        sid, _ = self.seed_session("delivery_time")
        tree = self.inject_candidate(sid, "A")
        job = self.ops.do_check(sid, "A")
        done = await_job(self.jobs, job["job_id"])
        self.assertEqual(done["status"], "succeeded", done.get("error"))
        self.assertTrue(done["result"]["passed"])
        self.assertEqual(done["result"]["scenario_status"], "access_revoked")
        self.assertEqual(len(done["result"]["tests_passed"]), 9)
        session = self.store.load(sid)
        self.assertEqual(session["candidates"]["A"]["status"], "checked")

    def test_failed_check_is_preserved_and_blocks_commit(self):
        """A semantically broken candidate really fails `go test`; the
        failure is recorded and commit is refused."""
        sid, _ = self.seed_session("delivery_time")
        good_tree = self.inject_candidate(sid, "good")
        good = await_job(self.jobs, self.ops.do_check(sid, "good")["job_id"])
        self.assertTrue(good["result"]["passed"])
        good_before = self.store.load(sid)["candidates"]["good"].copy()

        def break_delivery_check(cdir):
            # Inside the generator boundary: skip the delivery-time
            # access re-check, so revoked access wrongly exports.
            p = Path(cdir) / "queued" / "worker.go"
            original = p.read_text()
            text = original.replace(
                "if !access.Allowed(job.TenantID, job.UserID) {",
                "if false { // BROKEN (delivery access check skipped)")
            assert text != original
            p.write_text(text)

        # NOTE: inject the record directly to simulate a candidate tree
        # with this content (as a generator-produced tree would be).
        cdir, pdir = self.ops.cand_dir(sid, "F"), self.ops.parent_dir(sid, "F")
        shutil.copytree(self.ops.clone_dir(sid), cdir,
                        ignore=shutil.ignore_patterns(".git"))
        break_delivery_check(cdir)
        snap = tree_snapshot(cdir)
        session = self.store.load(sid)
        session["candidates"]["F"] = {
            "candidate": "F", "answer": "delivery_time", "intent_revision": 0,
            "source_parent": session["repo"]["resolved_commit"],
            "tree": tree_hash(snap), "files": len(snap),
            "changed": ["queued/worker.go"], "status": "generated",
            "protected": server.pin_protected(self.ops.clone_dir(sid))}
        self.store.save(session)
        job = self.ops.do_check(sid, "F")
        done = await_job(self.jobs, job["job_id"])
        self.assertEqual(done["status"], "succeeded", done.get("error"))
        self.assertFalse(done["result"]["passed"])
        self.assertEqual(done["result"]["failing_step"], "test")
        session = self.store.load(sid)
        self.assertEqual(session["candidates"]["F"]["status"], "check_failed")
        # Failed verification preserved with logs.
        ver = session["verifications"][-1]
        self.assertFalse(ver["passed"])
        self.assertIn("FAIL", ver["steps"]["test"]["stdout"])
        self.assertEqual(session["candidates"]["good"], good_before)
        self.assertEqual(tree_hash(tree_snapshot(self.ops.cand_dir(sid, "good"))), good_tree)
        self.assertTrue(session["verifications"][0]["passed"])
        with self.assertRaises(ValueError):
            self.ops.do_commit(sid, "F", "must not commit")

    def test_stale_source_refuses_check(self):
        sid, _ = self.seed_session()
        self.inject_candidate(sid, "S")
        with open(os.path.join(self.ops.cand_dir(sid, "S"), "queued",
                               "queue.go"), "a") as f:
            f.write("\n// post-generation tamper\n")
        job = self.ops.do_check(sid, "S")
        done = await_job(self.jobs, job["job_id"])
        self.assertEqual(done["status"], "failed")
        self.assertIn("changed since generation", done["error"])

    def test_cancellation_preserves_state(self):
        started = threading.Event()

        def slow(job, cancel, progress):
            started.set()
            for i in range(300):
                if cancel.is_set():
                    raise RuntimeError("cancelled by test")
                time.sleep(0.1)
            return {"never": True}

        # Duplicate mutation request deduplicates to the in-flight job.
        job, fresh = self.jobs.submit("sess-test", "slow-test", {}, slow,
                                      idempotency_key="slow:1")
        dup, fresh_dup = self.jobs.submit("sess-test", "slow-test", {}, slow,
                                          idempotency_key="slow:1")
        self.assertTrue(fresh)
        self.assertFalse(fresh_dup)
        self.assertEqual(job["job_id"], dup["job_id"])
        self.assertTrue(started.wait(timeout=10))
        cancelled = self.jobs.cancel(job["job_id"])
        self.assertTrue(cancelled["cancel_requested"])
        done = await_job(self.jobs, job["job_id"], timeout=60)
        self.assertEqual(done["status"], "cancelled")

    def test_push_retry_deduplicates_without_new_commits(self):
        sid, _ = self.seed_session()
        clone = self.ops.clone_dir(sid)
        # Local commit + push through the real op path.
        with open(os.path.join(clone, "queued", "queue.go"), "a") as f:
            f.write("\n// demo change\n")
        sh("git", "-C", clone, "add", "-A")
        sh("git", "-C", clone, "commit", "-m", "demo")
        commit = sh("git", "-C", clone, "rev-parse", "HEAD").stdout.strip()
        session = self.store.load(sid)
        session["candidates"]["A"] = {"candidate": "A", "status": "committed",
                                      "commit": commit}
        session["commits"].append(
            {"candidate": "A", "commit": commit, "parent": "seed",
             "message": "demo", "ref": "main", "push": None})
        self.store.save(session)
        before = sh("git", "-C", self.origin, "rev-list", "--count",
                    "main").stdout.strip()
        first = await_job(self.jobs, self.ops.do_push(sid, "A")["job_id"])
        self.assertEqual(first["status"], "succeeded", first.get("error"))
        self.assertTrue(first["result"]["pushed"])
        mid = sh("git", "-C", self.origin, "rev-list", "--count",
                 "main").stdout.strip()
        self.assertEqual(int(mid), int(before) + 1)
        # Retry after success: deduplicated, no new commit anywhere.
        second = await_job(self.jobs, self.ops.do_push(sid, "A")["job_id"])
        self.assertEqual(second["status"], "succeeded", second.get("error"))
        self.assertTrue(second["result"]["deduplicated"])
        after = sh("git", "-C", self.origin, "rev-list", "--count",
                   "main").stdout.strip()
        self.assertEqual(mid, after)
        head = sh("git", "-C", self.origin, "rev-parse",
                  "main").stdout.strip()
        self.assertEqual(head, commit)

    def test_commit_refuses_cross_intent_manifest(self):
        """checkX -> acceptY -> commitX must refuse: the committed tree
        would otherwise bind X's program to Y's intent manifest."""
        sid, _ = self.seed_session("delivery_time")
        self.inject_candidate(sid, "A")
        check = await_job(self.jobs, self.ops.do_check(sid, "A")["job_id"])
        self.assertEqual(check["status"], "succeeded", check.get("error"))
        self.assertTrue(check["result"]["passed"])
        # A later accept moves the clone manifest but not the candidate.
        self.ops.do_accept(sid, "queue_time")
        commit_job = self.ops.do_commit(sid, "A", "must not bind new intent")
        done = await_job(self.jobs, commit_job["job_id"])
        self.assertEqual(done["status"], "failed")
        self.assertIn("changed since the passing check", done["error"])
        session = self.store.load(sid)
        self.assertEqual(session["candidates"]["A"]["status"], "checked")
        self.assertEqual(session["commits"], [])

    def test_regeneration_under_settled_name_refused(self):
        sid, _ = self.seed_session()
        session = self.store.load(sid)
        session["candidates"]["A"] = {"candidate": "A", "status": "checked"}
        self.store.save(session)
        with self.assertRaises(ValueError):
            self.ops.do_generate(sid, "A")

    def test_regeneration_under_generated_name_refused_without_touching(self):
        """Finding 3: even a merely generated (unchecked) candidate is
        immutable — a repeat generation must not delete its workspaces."""
        sid, _ = self.seed_session()
        before = self.inject_candidate(sid, "A")
        cdir, pdir = self.ops.cand_dir(sid, "A"), self.ops.parent_dir(sid, "A")
        with self.assertRaises(ValueError):
            self.ops.do_generate(sid, "A")
        self.assertEqual(tree_hash(tree_snapshot(cdir)), before)
        self.assertTrue(os.path.isdir(pdir))
        session = self.store.load(sid)
        self.assertEqual(session["candidates"]["A"]["tree"], before)

    def test_generate_without_provider_key_retires_partial_without_record(
            self):
        """Findings 3+6: a generation that cannot start leaves no candidate
        record and no half-named workspaces; the staging is retired."""
        sid, _ = self.seed_session()
        saved = os.environ.pop("META_API_KEY", None)
        try:
            job = self.ops.do_generate(sid, "A")
            done = await_job(self.jobs, job["job_id"])
        finally:
            if saved is not None:
                os.environ["META_API_KEY"] = saved
        self.assertEqual(done["status"], "failed")
        self.assertIn("provider key", done["error"])
        session = self.store.load(sid)
        self.assertNotIn("A", session["candidates"])
        self.assertFalse(os.path.exists(self.ops.cand_dir(sid, "A")))
        self.assertFalse(os.path.exists(self.ops.parent_dir(sid, "A")))
        partials = [d for d in os.listdir(self.ops.receipt_dir(sid, "A"))
                    if d.startswith("partial-A-")]
        self.assertTrue(partials, "partial proposal retained for inspection")

    def test_resolve_generation_exit_code_first(self):
        """Finding 6 (pure): nonzero exit is failed construction even
        when the boundary verdict accepts the partial edits."""
        ok_verdict = {"decision": "accept", "changed": ["queued/queue.go"],
                      "violations": []}
        status, _ = server.resolve_generation(7, ok_verdict)
        self.assertEqual(status, "failed")
        status, _ = server.resolve_generation(
            0, {"decision": "reject", "changed": [],
                "violations": ["modified protected file: queued/queued_test.go"]})
        self.assertEqual(status, "rejected")
        status, _ = server.resolve_generation(0, ok_verdict)
        self.assertEqual(status, "succeeded")

    def test_two_tree_oracle_rewrite_is_pinned_down(self):
        """Finding 4: a generator rewriting the oracle in BOTH the
        candidate and the sibling parent snapshot is still rejected,
        because validation uses the pre-invocation pin."""
        sid, _ = self.seed_session()
        cdir, pdir = self.ops.cand_dir(sid, "G"), self.ops.parent_dir(sid, "G")
        shutil.copytree(self.ops.clone_dir(sid), cdir,
                        ignore=shutil.ignore_patterns(".git"))
        pinned = server.pin_protected(cdir)
        shutil.copytree(cdir, pdir)
        gut = "package queued\n"
        # The stand-in rewrites the oracle in BOTH trees, then makes one
        # allowed-looking program edit in the candidate only.
        for d in (cdir, pdir):
            with open(os.path.join(d, "queued", "queued_test.go"), "w") as f:
                f.write(gut)
        with open(os.path.join(cdir, "queued", "queue.go"), "a") as f:
            f.write("\n// allowed-looking edit\n")
        # The mutable-snapshot comparison alone sees no oracle change.
        self.assertEqual(server.verify_boundary(pdir, cdir)["decision"],
                         "accept")
        # The pinned inventory catches both rewrites.
        self.assertTrue(server.validate_pinned(cdir, pinned))
        self.assertTrue(server.validate_pinned(pdir, pinned))

    def test_protected_scenario_command_rewrite_rejected_op_path(self):
        """Review-2 remaining P1 (op path): a generator rewriting the
        protected scenario command in BOTH the candidate and the sibling
        parent snapshot — plus one allowed-looking edit — is rejected:
        the full pre-invocation pin catches what the parent/candidate
        diff cannot see. Previously this published a candidate whose
        real checks passed 9/9 with a fabricated exported scenario."""
        sid, _ = self.seed_session()
        pdir = self.ops.parent_dir(sid, "Scenario")
        fake = ('package main\nimport "fmt"\nfunc main() { '
                'fmt.Println("process: status=exported events=2") }\n')
        stub = os.path.join(self.tmp, "generator-Scenario")
        with open(stub, "w") as f:
            f.write("#!/usr/bin/env python3\n"
                    "from pathlib import Path\n"
                    "import sys\n"
                    f"fake = {fake!r}\n"
                    'Path("cmd/exportdemo/main.go").write_text(fake)\n'
                    f"Path({str(pdir)!r}, "
                    '"cmd/exportdemo/main.go").write_text(fake)\n'
                    'p = Path("queued/queue.go")\n'
                    'p.write_text(p.read_text() + "\\n// allowed edit\\n")\n'
                    "sys.exit(0)\n")
        os.chmod(stub, 0o700)
        old_bin, old_key = server.MUSE_BIN, os.environ.get("META_API_KEY")
        server.MUSE_BIN = stub
        os.environ["META_API_KEY"] = "nonsecret-local-test-sentinel"
        try:
            done = await_job(
                self.jobs, self.ops.do_generate(sid, "Scenario")["job_id"],
                timeout=120)
        finally:
            server.MUSE_BIN = old_bin
            if old_key is None:
                os.environ.pop("META_API_KEY", None)
            else:
                os.environ["META_API_KEY"] = old_key
        self.assertEqual(done["status"], "failed", done.get("error"))
        session = self.store.load(sid)
        self.assertNotIn("Scenario", session["candidates"])
        proposal = session["proposals"][-1]
        self.assertEqual(proposal["status"], "rejected")
        self.assertTrue(any("cmd/exportdemo/main.go" in v
                           for v in proposal["boundary"]["violations"]),
                        proposal["boundary"]["violations"])

    def test_check_refuses_oracle_drift_against_pin(self):
        """Finding 4 (op path): oracle rewritten after the pin fails the
        check loudly instead of passing with zero named tests."""
        sid, _ = self.seed_session("delivery_time")
        self.inject_candidate(sid, "G")
        cdir = self.ops.cand_dir(sid, "G")
        with open(os.path.join(cdir, "queued", "queued_test.go"), "w") as f:
            f.write("package queued\n")
        # Re-record the tree as if a corrupted authority accepted it.
        snap = tree_snapshot(cdir)
        session = self.store.load(sid)
        session["candidates"]["G"]["tree"] = tree_hash(snap)
        self.store.save(session)
        done = await_job(self.jobs, self.ops.do_check(sid, "G")["job_id"])
        self.assertEqual(done["status"], "failed")
        self.assertIn("oracle differs", done["error"])

    def test_check_requires_nine_named_tests(self):
        """Finding 4 (gate): a vacuously passing suite with the oracle
        removed records a failed verification, never a pass."""
        sid, _ = self.seed_session("delivery_time")
        cdir, pdir = self.ops.cand_dir(sid, "V"), self.ops.parent_dir(sid, "V")
        shutil.copytree(self.ops.clone_dir(sid), cdir,
                        ignore=shutil.ignore_patterns(".git"))
        shutil.copytree(self.ops.clone_dir(sid), pdir,
                        ignore=shutil.ignore_patterns(".git"))
        with open(os.path.join(cdir, "queued", "queued_test.go"), "w") as f:
            f.write("package queued\n")
        snap = tree_snapshot(cdir)
        session = self.store.load(sid)
        # Pin AFTER the gutting to isolate the named-tests gate itself.
        session["candidates"]["V"] = {
            "candidate": "V", "answer": "delivery_time", "intent_revision": 0,
            "source_parent": session["repo"]["resolved_commit"],
            "tree": tree_hash(snap), "files": len(snap),
            "changed": ["queued/queued_test.go"], "status": "generated",
            "protected": server.pin_protected(cdir)}
        self.store.save(session)
        done = await_job(self.jobs, self.ops.do_check(sid, "V")["job_id"])
        self.assertEqual(done["status"], "succeeded", done.get("error"))
        self.assertFalse(done["result"]["passed"])
        self.assertEqual(done["result"]["failing_step"], "test")
        ver = self.store.load(sid)["verifications"][-1]
        self.assertFalse(ver["passed"])
        self.assertIn("oracle", ver["steps"])
        self.assertEqual(len(server.EXPECTED_TESTS), 9)

    def test_commit_binds_full_tree_including_manifest(self):
        """Finding 1 (success path): the committed content — manifest,
        oracle, and program — is byte-identical to the checked tree."""
        sid, _ = self.seed_session("delivery_time")
        tree = self.inject_candidate(sid, "A")
        check = await_job(self.jobs, self.ops.do_check(sid, "A")["job_id"])
        self.assertTrue(check["result"]["passed"], check.get("error"))
        done = await_job(
            self.jobs, self.ops.do_commit(sid, "A", "bind full tree")["job_id"])
        self.assertEqual(done["status"], "succeeded", done.get("error"))
        clone = self.ops.clone_dir(sid)
        committed_manifest = sh(
            "git", "-C", clone, "show", "HEAD:.trajectory/intent.json").stdout
        with open(os.path.join(
                self.ops.cand_dir(sid, "A"), ".trajectory",
                "intent.json")) as f:
            checked_manifest = f.read()
        self.assertEqual(committed_manifest, checked_manifest)
        self.assertIn('"delivery_time"', committed_manifest)
        session = self.store.load(sid)
        self.assertEqual(session["commits"][-1]["tree"], tree)

    def test_push_older_candidate_after_newer_lands_fails_cleanly(self):
        """Finding 2: with the remote at B, pushing A fails without
        moving the remote or mislabeling A as pushed."""
        sid, _ = self.seed_session()
        clone = self.ops.clone_dir(sid)
        with open(os.path.join(clone, "queued", "queue.go"), "a") as f:
            f.write("\n// A change\n")
        sh("git", "-C", clone, "add", "-A")
        sh("git", "-C", clone, "commit", "-m", "A")
        commit_a = sh("git", "-C", clone, "rev-parse", "HEAD").stdout.strip()
        with open(os.path.join(clone, "queued", "queue.go"), "a") as f:
            f.write("\n// B change\n")
        sh("git", "-C", clone, "add", "-A")
        sh("git", "-C", clone, "commit", "-m", "B")
        commit_b = sh("git", "-C", clone, "rev-parse", "HEAD").stdout.strip()
        session = self.store.load(sid)
        session["candidates"]["A"] = {"candidate": "A", "status": "committed",
                                      "commit": commit_a}
        session["candidates"]["B"] = {"candidate": "B", "status": "committed",
                                      "commit": commit_b}
        session["commits"] = [
            {"candidate": "A", "commit": commit_a, "parent": "seed",
             "message": "A", "ref": "main", "push": None},
            {"candidate": "B", "commit": commit_b, "parent": commit_a,
             "message": "B", "ref": "main", "push": None}]
        self.store.save(session)
        pushed_b = await_job(self.jobs, self.ops.do_push(sid, "B")["job_id"])
        self.assertEqual(pushed_b["status"], "succeeded", pushed_b.get("error"))
        stale_a = await_job(self.jobs, self.ops.do_push(sid, "A")["job_id"])
        self.assertEqual(stale_a["status"], "failed")
        head = sh("git", "--git-dir", self.origin, "rev-parse",
                  "main").stdout.strip()
        self.assertEqual(head, commit_b)
        session = self.store.load(sid)
        self.assertEqual(session["candidates"]["A"]["status"], "committed")
        push_rec = [c for c in session["commits"]
                    if c["commit"] == commit_a][0]["push"]
        self.assertFalse(push_rec["pushed"])

    def test_run_drains_large_output_without_deadlock(self):
        """Finding 7: a 1MB stdout no longer wedges the bounded run;
        output streams to files while waiting and the tail is kept."""
        rc, out, err = server.run(
            ["python3", "-c", 'print("x"*1000000)'], timeout=30)
        self.assertEqual(rc, 0)
        self.assertEqual(len(out), 512 * 1024)
        self.assertTrue(out.endswith("\n"))

    def test_cancel_kills_descendants_before_late_write(self):
        """Finding 5: a cancelled run's descendants cannot write after
        cancellation is reported."""
        marker = os.path.join(self.tmp, "late-marker")
        cancel = threading.Event()
        result = {}

        def target():
            result["r"] = server.run(
                ["bash", "-c", f"sleep 1.2; touch {marker}; echo done"],
                timeout=30, cancel=cancel)

        t = threading.Thread(target=target)
        t.start()
        time.sleep(0.3)
        cancel.set()
        t.join(timeout=20)
        self.assertEqual(result["r"][0], "cancelled")
        time.sleep(2.0)
        self.assertFalse(os.path.exists(marker))

    def test_unsupported_repo_and_bad_tokens_refused(self):
        session = self.store.new_session()
        with self.assertRaises(ValueError):
            self.ops.do_import(session["session_id"], "someone/else", "main")
        with self.assertRaises(ValueError):
            self.ops.do_accept("../escape", "queue_time")
        with self.assertRaises(ValueError):
            self.ops.do_generate(session["session_id"], "../../escape")

    def test_get_reads_do_not_mutate(self):
        from http.server import ThreadingHTTPServer
        port = 18731
        server.Handler.store = self.store
        server.Handler.jobs = self.jobs
        server.Handler.ops = self.ops
        httpd = ThreadingHTTPServer(("127.0.0.1", port), server.Handler)
        t = threading.Thread(target=httpd.serve_forever, daemon=True)
        t.start()
        try:
            def get(path):
                with urllib.request.urlopen(
                        f"http://127.0.0.1:{port}{path}") as r:
                    return json.loads(r.read().decode())

            def post(path, obj):
                req = urllib.request.Request(
                    f"http://127.0.0.1:{port}{path}",
                    data=json.dumps(obj).encode(),
                    headers={"Content-Type": "application/json"}, method="POST")
                with urllib.request.urlopen(req) as r:
                    return json.loads(r.read().decode())

            self.assertEqual(get("/status")["service"], "trajectory-companion")
            created = post("/sessions", {})
            sid = created["session_id"]
            before = open(self.store.path(sid)).read()
            get(f"/sessions/{sid}")
            get(f"/sessions/{sid}")
            self.assertEqual(open(self.store.path(sid)).read(), before)
        finally:
            httpd.shutdown()


if __name__ == "__main__":
    unittest.main(verbosity=2)
