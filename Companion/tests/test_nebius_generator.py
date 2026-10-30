"""Nebius construction boundary: model output is data, never authority."""
import json
import os
from pathlib import Path
import sys
import tempfile
import shutil
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import server


class NebiusGeneratorTests(unittest.TestCase):
    def test_public_fixture_can_use_local_checks_without_actions_workflow(self):
        fixture = Path(__file__).resolve().parents[1] / "fixtures/delivery-baseline"
        with tempfile.TemporaryDirectory() as root:
            target = Path(root) / "repo"
            shutil.copytree(fixture, target)
            (target / ".github/workflows/ci.yml").unlink()
            pinned = server.pin_protected(str(target))
            self.assertNotIn(".github/workflows/ci.yml", pinned)
            self.assertEqual(server.validate_pinned(str(target), pinned), [])
            self.assertEqual(len(server.checker_content_id(str(target))), 64)

    def test_selected_nebius_provider_uses_host_key_only(self):
        with mock.patch.dict(os.environ, {
            "TRAJECTORY_GENERATOR_PROVIDER": "nebius",
            "NEBIUS_API_KEY": "test-nebius-secret",
            "META_API_KEY": "other-secret",
        }, clear=True):
            identity = server.generator_identity()
            argv, stdin = server.generator_command(identity, "/tmp/workspace", "/tmp/prompt", "run-1")
            child = server.scrub_env_for_generator()
        self.assertEqual(identity["model"], "nvidia/Nemotron-3_5-Lightning")
        self.assertEqual(identity["provider"], "nebius")
        self.assertIn("nebius_generate.py", " ".join(argv))
        self.assertEqual(stdin, b"")
        self.assertEqual(child["NEBIUS_API_KEY"], "test-nebius-secret")
        self.assertNotIn("META_API_KEY", child)
        self.assertNotIn("test-nebius-secret", " ".join(argv))

    def test_only_two_bounded_go_files_are_accepted(self):
        import nebius_generate
        good = {"queued/queue.go": "package queued\n", "queued/worker.go": "package queued\n"}
        response = {"choices": [{"finish_reason": "stop", "message": {"content": json.dumps(good)}}]}
        self.assertEqual(nebius_generate.extract_candidate(response), good)
        response["choices"][0]["message"]["content"] = json.dumps({**good, "go.mod": "bad"})
        with self.assertRaises(ValueError):
            nebius_generate.extract_candidate(response)

    def test_failed_response_does_not_change_workspace(self):
        import nebius_generate
        with tempfile.TemporaryDirectory() as root:
            queued = Path(root) / "queued"
            queued.mkdir()
            for name in ("queue.go", "worker.go"):
                (queued / name).write_text("package queued\n")
            with self.assertRaises(ValueError):
                nebius_generate.apply_candidate(Path(root), {"queued/queue.go": "package queued\n", "bad": "x"})
            self.assertEqual((queued / "queue.go").read_text(), "package queued\n")
