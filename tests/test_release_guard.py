"""Offline regression tests for the official release boundary and IPA checks."""
import importlib.util
import os
import plistlib
import re
import subprocess
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/build.yml"


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


metadata = load_script("ipa_metadata")


def jobs_from_workflow():
    source = WORKFLOW.read_text(encoding="utf-8")
    jobs = source.split("\njobs:\n", 1)[1]
    return source, dict(re.findall(r"^  ([a-z][\w-]*):\n(.*?)(?=^  [a-z][\w-]*:\n|\Z)", jobs, re.M | re.S))


def steps_from_job(job):
    return dict(re.findall(r"^      - name: ([^\n]+)\n(.*?)(?=^      - name: |\Z)", job, re.M | re.S))


class WorkflowGuardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source, cls.jobs = jobs_from_workflow()

    def test_only_main_non_variant_can_reach_publish(self):
        publish = self.jobs["publish"]
        condition = re.search(r"^    if: (.+)$", publish, re.M).group(1)
        self.assertEqual(condition, "${{ github.ref == 'refs/heads/main' && !inputs.variant }}")
        # Model the actual expression's two inputs for both supported triggers.
        scenarios = [
            ("push", "refs/heads/main", False, True),
            ("push", "refs/heads/arena/experiment", False, False),
            ("workflow_dispatch", "refs/heads/main", False, True),
            ("workflow_dispatch", "refs/heads/main", True, False),
            ("workflow_dispatch", "refs/heads/arena/experiment", False, False),
            ("workflow_dispatch", "refs/heads/arena/experiment", True, False),
            ("push", "refs/tags/main", False, False),
        ]
        for event, ref, variant, expected in scenarios:
            with self.subTest(event=event, ref=ref, variant=variant):
                self.assertEqual(ref == "refs/heads/main" and not variant, expected)

    def test_builds_remain_available_to_branches_and_variants(self):
        build = self.jobs["build"]
        self.assertIsNone(re.search(r"^    if:", build, re.M))
        upload = steps_from_job(build)["Upload IPA"]
        self.assertNotRegex(upload, r"(?m)^        if:")
        self.assertIn("inputs.variant && 'MoodyVidTest-ipa' || 'MoodyVid-ipa'", upload)
        self.assertIn("actions/upload-artifact@", upload)
        self.assertIn("needs: test", build)

    def test_write_token_and_all_release_mutations_are_in_guarded_job(self):
        source, jobs = self.source, self.jobs
        self.assertRegex(source, r"(?m)^permissions:\n  contents: read$")
        self.assertEqual(len(re.findall(r"(?m)^\s+contents: write$", source)), 1)
        self.assertIn("      contents: write", jobs["publish"])
        for name, job in jobs.items():
            if name != "publish":
                self.assertNotIn("gh release", job)
                self.assertNotIn("git push", job)
                self.assertNotIn("--out source.json", job)
        publish = jobs["publish"]
        self.assertIn("needs: build", publish)
        self.assertIn("cancel-in-progress: false", publish)
        self.assertIn("git push origin HEAD:refs/heads/main", publish)
        self.assertNotIn("GITHUB_REF_NAME", publish)
        self.assertIn("- 'source.json'", source.split("\njobs:\n", 1)[0])

    def test_each_publication_step_checks_the_latest_revision(self):
        steps = steps_from_job(self.jobs["publish"])
        self.assertIn('scripts/publish_revision.py "$GITHUB_SHA" "$TIP"', steps["Check current main revision"])
        for name in ("Download official IPA artifact", "Validate official IPA metadata", "Publish release",
                     "Verify download link", "Write AltStore source", "Commit source.json"):
            with self.subTest(step=name):
                self.assertIn("if: ${{ steps.revision.outputs.current == 'true' }}", steps[name])
        self.assertIn("--expected-build", steps["Validate official IPA metadata"])
        self.assertIn('scripts/publish_revision.py "$BASE" "$TIP"', steps["Commit source.json"])

    def test_release_rechecks_main_before_metadata_and_asset_changes(self):
        release = steps_from_job(self.jobs["publish"])["Publish release"]
        self.assertIn('scripts/publish_revision.py "$GITHUB_SHA" "$tip"', release)
        calls = [match.start() for match in re.finditer(r"(?m)^          check_main_is_publishable$", release)]
        self.assertEqual(len(calls), 2)
        self.assertLess(calls[0], release.index("gh release edit"))
        self.assertLess(release.index("gh release edit"), calls[1])
        self.assertLess(calls[1], release.index("gh release upload"))


class IpaMetadataTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "MoodyVid.ipa"
        self.info = {
            "CFBundleIdentifier": "com.mody.moodyvid",
            "CFBundleExecutable": "MoodyVid",
            "CFBundleShortVersionString": "0.2.0",
            "CFBundleVersion": "42",
            "MinimumOSVersion": "15.0",
        }

    def write_ipa(self, info=None, path=metadata.INFO_PATH, duplicate=False):
        data = plistlib.dumps(self.info if info is None else info)
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.path, "w") as ipa:
                ipa.writestr(path, data)
                if duplicate:
                    ipa.writestr(path, data)

    def test_official_ipa(self):
        self.write_ipa()
        result = metadata.read_metadata(self.path, "42")
        self.assertEqual(result["VERSION"], "0.2.0")
        self.assertEqual(result["MINOS"], "15.0")
        self.assertEqual(result["SIZE"], str(self.path.stat().st_size))

    def test_rejects_variant_and_wrong_run(self):
        self.info["CFBundleIdentifier"] = "com.mody.moodyvid.test"
        self.write_ipa()
        with self.assertRaisesRegex(ValueError, "bundle ID"):
            metadata.read_metadata(self.path, "42")
        self.info["CFBundleIdentifier"] = "com.mody.moodyvid"
        self.write_ipa()
        with self.assertRaisesRegex(ValueError, "build number"):
            metadata.read_metadata(self.path, "41")

    def test_rejects_other_executable_and_path(self):
        self.info["CFBundleExecutable"] = "MoodyVidTest"
        self.write_ipa()
        with self.assertRaisesRegex(ValueError, "executable"):
            metadata.read_metadata(self.path, "42")
        self.info["CFBundleExecutable"] = "MoodyVid"
        self.write_ipa(path="Payload/MoodyVidTest.app/Info.plist")
        with self.assertRaisesRegex(ValueError, "missing"):
            metadata.read_metadata(self.path, "42")

    def test_rejects_duplicate_plist_and_environment_injection(self):
        self.write_ipa(duplicate=True)
        with self.assertRaisesRegex(ValueError, "duplicated"):
            metadata.read_metadata(self.path, "42")
        self.info["CFBundleShortVersionString"] = "0.2.0\nINJECTED=1"
        self.write_ipa()
        with self.assertRaisesRegex(ValueError, "version"):
            metadata.read_metadata(self.path, "42")
        with self.assertRaisesRegex(ValueError, "expected build"):
            metadata.read_metadata(self.path, "42\nINJECTED=1")

    def test_rejects_non_ipa(self):
        self.path.write_bytes(b"not a zip")
        with self.assertRaises(zipfile.BadZipFile):
            metadata.read_metadata(self.path, "42")


class RevisionGuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        self.git("init", "-q")
        (self.repo / "README.md").write_text("readme v1\n")
        (self.repo / "code.m").write_text("code v1\n")
        (self.repo / "source.json").write_text("{}\n")
        self.base = self.commit("base")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, env=self.env, text=True).strip()

    def commit(self, message):
        self.git("add", "-A")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
                 "commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def allowed(self, old, new):
        return subprocess.run(["python3", str(ROOT / "scripts/publish_revision.py"), old, new],
                              cwd=self.repo, env=self.env, capture_output=True).returncode

    def test_same_and_docs_only_are_publishable(self):
        self.assertEqual(self.allowed(self.base, self.base), 0)
        (self.repo / "README.md").write_text("readme v2\n")
        (self.repo / "LICENSE").write_text("license\n")
        docs = self.commit("docs only")
        self.assertEqual(self.allowed(self.base, docs), 0)

    def test_code_change_and_earlier_publication_are_stale(self):
        (self.repo / "code.m").write_text("code v2\n")
        code = self.commit("code")
        self.assertEqual(self.allowed(self.base, code), 1)
        (self.repo / "source.json").write_text('{"build":42}\n')
        published = self.commit("published")
        self.assertEqual(self.allowed(code, published), 1)
        self.assertEqual(self.allowed(published, code), 1)  # not an ancestor

    def test_renaming_docs_into_code_is_not_docs_only(self):
        (self.repo / "README.md").rename(self.repo / "code2.m")
        renamed = self.commit("rename")
        self.assertEqual(self.allowed(self.base, renamed), 1)

    def test_unknown_revision_is_an_error(self):
        self.assertEqual(self.allowed("not-a-revision", self.base), 2)


if __name__ == "__main__":
    unittest.main()
