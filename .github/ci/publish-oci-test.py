#!/usr/bin/env python3
"""Exercise the OCI publisher with real Helm packages and isolated CLI services."""

import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tarfile
import unittest


ISSUER = "https://token.actions.githubusercontent.com"
IDENTITY = "https://github.com/skyhook-io/helm-charts/.github/workflows/release.yml@refs/heads/main"
SHA = "a" * 40
SCRIPT = Path(__file__).resolve().parents[1] / "scripts/publish-oci.sh"
INDEX_SCRIPT = SCRIPT.with_name("index-published-charts.sh")


def fake_cli(tool):
    """Keep remote service state across separate publisher attempts."""
    state_path = Path(os.environ["PUBLISH_TEST_STATE"])
    state = json.loads(state_path.read_text())
    args = sys.argv[1:]
    state["events"].append([tool, *args])

    def finish(code=0, output=""):
        state_path.write_text(json.dumps(state))
        print(output, end="", file=sys.stdout if code == 0 else sys.stderr)
        raise SystemExit(code)

    def option(name):
        return args[args.index(name) + 1]

    if tool == "gh":
        if args[0] == "api":
            endpoint = args[args.index("api") + 1]
            if endpoint == "--paginate":
                endpoint = args[2]
            if "/releases?" in endpoint:
                if state.get("list_failure"):
                    finish(1, "GitHub API unavailable\n")
                pages = state["pages"] if "--paginate" in args else state["pages"][:1]
                output = ""
                for page in pages:
                    result = subprocess.run(
                        ["jq", "-r", option("--jq")], input=json.dumps(page),
                        text=True, capture_output=True, check=True,
                    )
                    output += result.stdout
                finish(output=output)
            if "/commits/refs/tags/" in endpoint:
                tag = endpoint.split("/commits/refs/tags/", 1)[1]
                finish(output=state["tag_commits"][tag] + "\n")
        if args[:2] == ["release", "download"]:
            tag = args[2]
            if state.get("download_failure"):
                finish(1, "Release asset unavailable\n")
            source = Path(state["assets"][tag])
            if option("--pattern") != source.name:
                finish(1, "Wrong release asset requested\n")
            shutil.copyfile(source, Path(option("--dir")) / source.name)
            finish()

    if tool == "cr":
        if args != ["index", "--owner", "skyhook-io", "--git-repo", "helm-charts", "--push"]:
            finish(1, "Unexpected index command\n")
        for package in Path(".cr-release-packages").glob("*.tgz"):
            canonical = Path(state["assets"][package.stem])
            if package.read_bytes() != canonical.read_bytes():
                finish(1, "Index would hash a repackaged archive\n")
        finish()

    if tool == "helm":
        if args[:2] == ["show", "chart"] or args[0] == "package":
            state_path.write_text(json.dumps(state))
            raise SystemExit(subprocess.run([os.environ["PUBLISH_TEST_HELM"], *args]).returncode)
        if args[:2] == ["registry", "login"]:
            if sys.stdin.read() != "test-token":
                finish(1, "Registry credentials missing\n")
            config = Path(os.environ["HELM_REGISTRY_CONFIG"])
            if config.parent != Path(os.environ["DOCKER_CONFIG"]):
                finish(1, "Helm and Cosign credentials are separate\n")
            config.write_text(json.dumps({"auths": {"ghcr.io": {"auth": "dGVzdDp0ZXN0LXRva2Vu"}}}))
            finish()
        if args[0] == "pull":
            name = args[1].rsplit("/", 1)[1]
            version = option("--version")
            tag = f"{name}-{version}"
            if state.get("pull_failure"):
                finish(1, state["pull_failure"] + "\n")
            if tag not in state["registry"]:
                image = args[1].removeprefix("oci://")
                finish(1, f"Error: {image}:{version.replace('+', '_')}: not found\n")
            entry = state["registry"][tag]
            shutil.copyfile(entry["archive"], Path(option("--destination")) / f"{tag}.tgz")
            digest = entry["digest"]
        elif args[0] == "push":
            tag = Path(args[1]).name.removesuffix(".tgz")
            if tag in state["registry"]:
                finish(1, "Attempted to replace an immutable chart version\n")
            if state.get("push_failure") == tag:
                finish(1, "Registry push failed\n")
            archive = Path(state_path.parent / f"registry-{tag}.tgz")
            shutil.copyfile(args[1], archive)
            digest = "sha256:" + hashlib.sha256(archive.read_bytes()).hexdigest()
            state["registry"][tag] = {"archive": str(archive), "digest": digest}
        else:
            finish(1, "Unexpected Helm command\n")
        digest_output = state.get("digest_output", f"Digest: {digest}\n")
        finish(output=digest_output)

    if tool == "cosign":
        reference = args[-1]
        if not reference.startswith(("ghcr.io/skyhook-io/charts/radar-hub@sha256:",
                                     "ghcr.io/skyhook-io/charts/radar@sha256:")):
            finish(1, "Cosign must receive an immutable Radar or Radar Hub digest\n")
        if not (Path(os.environ["DOCKER_CONFIG"]) / "config.json").is_file():
            finish(1, "Cosign registry credentials missing\n")
        if args[0] == "sign":
            if args[1:-1] != ["--yes", "--oidc-provider=github-actions"]:
                finish(1, "Signing must use GitHub OIDC\n")
            if state.get("sign_failure"):
                finish(1, "OIDC signing failed\n")
            state["signatures"][reference] = {
                "identity": state.get("signer_identity", IDENTITY),
                "issuer": state.get("signer_issuer", ISSUER),
            }
            finish()
        if args[0] == "verify":
            expected = ["verify", "--certificate-oidc-issuer", ISSUER,
                        "--certificate-identity", IDENTITY, reference]
            signature = state["signatures"].get(reference)
            if args != expected or signature != {"identity": IDENTITY, "issuer": ISSUER}:
                finish(1, "Certificate identity or issuer mismatch\n")
            if state.get("verify_failure"):
                finish(1, "Signature verification failed\n")
            finish()

    finish(1, f"Unexpected {tool} command: {args}\n")


class PublishingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.helm = shutil.which("helm")
        if not cls.helm or not shutil.which("jq"):
            raise RuntimeError("Publishing tests need Helm and jq")
        cls.fixtures = tempfile.TemporaryDirectory()
        cls.fixture_root = Path(cls.fixtures.name)
        cls.assets = {}
        for name, version in [
            ("radar-hub", "1.2.3"), ("radar", "2.3.4"),
            ("skyhook-connector", "3.4.5"), ("radar-hub", "1.2.3-rc.1+build.2"),
            ("radar", "2.3.4-rc.1+build.2"),
        ]:
            chart = cls.fixture_root / f"{name}-{version}"
            chart.mkdir()
            (chart / "Chart.yaml").write_text(f"apiVersion: v2\nname: {name}\nversion: {version}\n")
            (chart / "templates").mkdir()
            (chart / "templates/configmap.yaml").write_text(
                "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: chart-fixture\n"
            )
            subprocess.run([cls.helm, "package", str(chart), "--destination", str(cls.fixture_root)],
                           check=True, capture_output=True)
            cls.assets[f"{name}-{version}"] = str(cls.fixture_root / f"{name}-{version}.tgz")

    @classmethod
    def tearDownClass(cls):
        cls.fixtures.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for tool in ("gh", "helm", "cosign", "cr"):
            shim = self.bin / tool
            shim.write_text(f"#!{sys.executable}\nimport os,runpy\nos.environ['PUBLISH_TEST_TOOL']={tool!r}\n"
                            f"runpy.run_path({str(Path(__file__).resolve())!r}, run_name='__main__')\n")
            shim.chmod(0o755)
        self.state = {
            "events": [], "pages": [[]], "tag_commits": {}, "assets": self.assets,
            "registry": {}, "signatures": {},
        }
        self.state_path = self.root / "state.json"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        PUBLISH_TEST_STATE=str(self.state_path), PUBLISH_TEST_HELM=self.helm,
                        GITHUB_REPOSITORY="skyhook-io/helm-charts", GITHUB_SHA=SHA,
                        GITHUB_ACTOR="test-publisher", GITHUB_TOKEN="test-token")

    def release(self, tag="radar-hub-1.2.3", *, sha=SHA, draft=False, page=0, tag_sha=SHA):
        while len(self.state["pages"]) <= page:
            self.state["pages"].append([])
        self.state["pages"][page].append({"tag_name": tag, "target_commitish": sha, "draft": draft})
        self.state["tag_commits"][tag] = tag_sha
        if tag.startswith(("radar-hub-", "radar-")):
            # Model the exact source chart in the workflow's checked-out commit.
            name = "radar-hub" if tag.startswith("radar-hub-") else "radar"
            source = self.root / "charts" / name
            source.parent.mkdir(exist_ok=True)
            shutil.copytree(self.fixture_root / tag, source, dirs_exist_ok=True)

    def run_publisher(self, *, succeeds=True, contains=None):
        self.state_path.write_text(json.dumps(self.state))
        result = subprocess.run(["bash", str(SCRIPT)], cwd=self.root, env=self.env,
                                text=True, capture_output=True)
        self.state = json.loads(self.state_path.read_text())
        self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)
        if contains is not None:
            self.assertIn(contains, result.stdout + result.stderr)
        return result

    def calls(self, tool, command):
        return [event for event in self.state["events"] if event[:2] == [tool, command]]

    def run_index(self, *, succeeds=True):
        self.state_path.write_text(json.dumps(self.state))
        result = subprocess.run(["bash", str(INDEX_SCRIPT)], cwd=self.root, env=self.env,
                                text=True, capture_output=True)
        self.state = json.loads(self.state_path.read_text())
        self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)
        return result

    def local_repackage(self):
        self.release()
        packages = self.root / ".cr-release-packages"
        packages.mkdir()
        package = packages / "radar-hub-1.2.3.tgz"
        # A retry can have different archive bytes despite unchanged chart files.
        package.write_bytes(Path(self.assets[package.stem]).read_bytes() + b"retry")
        return package

    def test_index_uses_canonical_release_archive_on_retry(self):
        package = self.local_repackage()
        self.run_index()
        self.assertEqual(package.read_bytes(), Path(self.assets[package.stem]).read_bytes())
        self.assertEqual(len(self.calls("cr", "index")), 1)

    def test_index_rejects_existing_version_at_another_commit(self):
        self.local_repackage()
        self.state["tag_commits"]["radar-hub-1.2.3"] = "b" * 40
        result = self.run_index(succeeds=False)
        self.assertIn("bump the chart version", result.stderr + result.stdout)
        self.assertFalse(self.calls("gh", "release"))
        self.assertFalse(self.calls("cr", "index"))

    def test_index_download_failure_does_not_publish_index(self):
        self.local_repackage()
        self.state["download_failure"] = True
        self.run_index(succeeds=False)
        self.assertFalse(self.calls("cr", "index"))

    def test_index_with_no_packages_does_not_publish(self):
        self.run_index()
        self.assertEqual(self.state["events"], [])

    def test_fresh_hub_publish_then_retry_without_cr_packages(self):
        self.release()
        self.run_publisher()
        first_digest = self.state["registry"]["radar-hub-1.2.3"]["digest"]
        self.run_publisher()
        self.assertEqual(len(self.calls("helm", "push")), 1)
        self.assertEqual(len(self.calls("cosign", "sign")), 2)
        self.assertEqual(len(self.calls("cosign", "verify")), 2)
        self.assertTrue(all(call[-1].endswith("@" + first_digest)
                            for call in self.calls("cosign", "sign")))
        self.assertFalse((self.root / ".cr-release-packages").exists())

    def test_sign_failure_is_repaired_without_repush(self):
        self.release()
        self.state["sign_failure"] = True
        self.run_publisher(succeeds=False, contains="OIDC signing failed")
        self.assertFalse(self.calls("cosign", "verify"))
        self.state["sign_failure"] = False
        self.run_publisher()
        self.assertEqual(len(self.calls("helm", "push")), 1)
        self.assertEqual(len(self.calls("cosign", "verify")), 1)

    def test_wrong_identity_issuer_and_verification_failure_fail_job(self):
        self.release()
        for field, value in [("signer_identity", "wrong-workflow"),
                             ("signer_issuer", "wrong-issuer"), ("verify_failure", True)]:
            with self.subTest(field=field):
                self.state[field] = value
                expected = "Signature verification failed" if field == "verify_failure" else "Certificate identity or issuer mismatch"
                self.run_publisher(succeeds=False, contains=expected)
                del self.state[field]
        self.assertEqual(len(self.calls("helm", "push")), 1)

    def test_unsigned_only_batch_has_no_cosign_calls(self):
        self.release("skyhook-connector-3.4.5")
        self.run_publisher()
        self.assertEqual(len(self.calls("helm", "push")), 1)
        self.assertFalse(any(event[0] == "cosign" for event in self.state["events"]))

    def test_partial_mixed_batch_retry_preserves_existing_digests(self):
        for tag in ("radar-2.3.4", "radar-hub-1.2.3", "skyhook-connector-3.4.5"):
            self.release(tag)
        self.state["push_failure"] = "skyhook-connector-3.4.5"
        self.run_publisher(succeeds=False, contains="Registry push failed")
        existing = dict(self.state["registry"])
        del self.state["push_failure"]
        self.run_publisher()
        for tag, entry in existing.items():
            self.assertEqual(self.state["registry"][tag], entry)
        self.assertEqual(len(self.state["registry"]), 3)
        self.assertEqual(len(self.calls("cosign", "verify")), 4)
        references = {call[-1] for call in self.calls("cosign", "verify")}
        expected = {f"ghcr.io/skyhook-io/charts/{name}@{existing[tag]['digest']}"
                    for name, tag in (("radar", "radar-2.3.4"), ("radar-hub", "radar-hub-1.2.3"))}
        self.assertEqual(references, expected)

    def test_fresh_radar_publish_then_retry_without_cr_packages(self):
        self.release("radar-2.3.4")
        self.run_publisher()
        digest = self.state["registry"]["radar-2.3.4"]["digest"]
        self.run_publisher()
        self.assertEqual(len(self.calls("helm", "push")), 1)
        self.assertEqual(len(self.calls("cosign", "sign")), 2)
        self.assertEqual(len(self.calls("cosign", "verify")), 2)
        self.assertTrue(all(call[-1] == f"ghcr.io/skyhook-io/charts/radar@{digest}"
                            for call in self.calls("cosign", "sign")))
        self.assertFalse((self.root / ".cr-release-packages").exists())

    def test_radar_sign_failure_is_repaired_without_repush(self):
        self.release("radar-2.3.4")
        self.state["sign_failure"] = True
        self.run_publisher(succeeds=False, contains="OIDC signing failed")
        self.assertFalse(self.calls("cosign", "verify"))
        self.state["sign_failure"] = False
        self.run_publisher()
        self.assertEqual(len(self.calls("helm", "push")), 1)
        self.assertEqual(len(self.calls("cosign", "verify")), 1)

    def test_radar_wrong_identity_issuer_and_verification_failure_fail_job(self):
        self.release("radar-2.3.4")
        for field, value in [("signer_identity", "wrong-workflow"),
                             ("signer_issuer", "wrong-issuer"), ("verify_failure", True)]:
            with self.subTest(field=field):
                self.state[field] = value
                expected = "Signature verification failed" if field == "verify_failure" else "Certificate identity or issuer mismatch"
                self.run_publisher(succeeds=False, contains=expected)
                del self.state[field]
        self.assertEqual(len(self.calls("helm", "push")), 1)

    def test_existing_radar_archive_mismatch_is_not_signed(self):
        self.release("radar-2.3.4")
        self.state["registry"]["radar-2.3.4"] = {
            "archive": self.assets["radar-hub-1.2.3"], "digest": "sha256:" + "b" * 64,
        }
        self.run_publisher(succeeds=False, contains="refusing to sign")
        self.assertFalse(self.calls("cosign", "sign"))
        self.assertFalse(self.calls("helm", "push"))

    def test_replaced_radar_release_asset_cannot_be_pushed_or_signed(self):
        self.release("radar-2.3.4")
        replacement = self.root / "radar-2.3.4.tgz"
        with tarfile.open(self.assets["radar-2.3.4"]) as source, tarfile.open(replacement, "w:gz") as target:
            for member in source:
                if member.name == "radar/templates/configmap.yaml":
                    payload = b"{{ fail \"replaced release asset\" }}"
                    member.size = len(payload)
                    target.addfile(member, io.BytesIO(payload))
                else:
                    target.addfile(member, source.extractfile(member))
        self.state["assets"] = dict(self.assets, **{"radar-2.3.4": str(replacement)})
        for existing in (False, True):
            with self.subTest(existing=existing):
                if existing:
                    self.state["registry"]["radar-2.3.4"] = {
                        "archive": str(replacement), "digest": "sha256:" + "b" * 64,
                    }
                self.run_publisher(succeeds=False, contains="does not match the chart at this run's commit")
        self.assertFalse(self.calls("helm", "push"))
        self.assertFalse(self.calls("cosign", "sign"))

    def test_radar_prerelease_build_metadata_uses_helm_oci_tag(self):
        self.release("radar-2.3.4-rc.1+build.2")
        self.run_publisher()
        self.run_publisher()
        self.assertEqual(len(self.calls("helm", "push")), 1)
        self.assertEqual(len(self.calls("cosign", "verify")), 2)

    def test_existing_hub_archive_mismatch_is_not_signed(self):
        self.release()
        self.state["registry"]["radar-hub-1.2.3"] = {
            "archive": self.assets["radar-2.3.4"], "digest": "sha256:" + "b" * 64,
        }
        self.run_publisher(succeeds=False, contains="refusing to sign")
        self.assertFalse(self.calls("cosign", "sign"))
        self.assertFalse(self.calls("helm", "push"))

    def test_replaced_release_asset_cannot_be_pushed_or_signed(self):
        self.release()
        replacement = self.root / "radar-hub-1.2.3.tgz"
        original = Path(self.assets["radar-hub-1.2.3"])
        with tarfile.open(original) as source, tarfile.open(replacement, "w:gz") as target:
            for member in source:
                if member.name == "radar-hub/templates/configmap.yaml":
                    payload = b"{{ fail \"replaced release asset\" }}"
                    member.size = len(payload)
                    target.addfile(member, io.BytesIO(payload))
                else:
                    target.addfile(member, source.extractfile(member))
        self.state["assets"] = dict(self.assets, **{"radar-hub-1.2.3": str(replacement)})
        for existing in (False, True):
            with self.subTest(existing=existing):
                if existing:
                    self.state["registry"]["radar-hub-1.2.3"] = {
                        "archive": str(replacement), "digest": "sha256:" + "b" * 64,
                    }
                self.run_publisher(succeeds=False, contains="does not match the chart at this run's commit")
        self.assertFalse(self.calls("helm", "push"))
        self.assertFalse(self.calls("cosign", "sign"))

    def test_extra_missing_duplicate_link_or_unsafe_members_are_not_signed(self):
        self.release()
        original = Path(self.assets["radar-hub-1.2.3"])
        for kind in ("extra", "missing", "duplicate", "link", "unsafe"):
            with self.subTest(kind=kind):
                replacement = self.root / f"{kind}/radar-hub-1.2.3.tgz"
                replacement.parent.mkdir()
                with tarfile.open(original) as source, tarfile.open(replacement, "w:gz") as target:
                    for member in source:
                        if kind == "missing" and member.name.endswith("templates/configmap.yaml"):
                            continue
                        target.addfile(member, source.extractfile(member))
                    if kind != "missing":
                        name = "radar-hub/templates/extra.yaml"
                        if kind == "duplicate":
                            name = "radar-hub/templates/configmap.yaml"
                        elif kind == "unsafe":
                            name = "../unsafe.yaml"
                        extra = tarfile.TarInfo(name)
                        if kind == "link":
                            extra.type = tarfile.SYMTYPE
                            extra.linkname = "templates/configmap.yaml"
                            target.addfile(extra)
                        else:
                            extra.size = 5
                            target.addfile(extra, io.BytesIO(b"extra"))
                self.state["assets"] = dict(self.assets, **{"radar-hub-1.2.3": str(replacement)})
                self.run_publisher(succeeds=False, contains="does not match the chart at this run's commit")
        self.assertFalse(self.calls("helm", "push"))
        self.assertFalse(self.calls("cosign", "sign"))

    def test_packaging_timestamps_do_not_change_signing_input(self):
        self.release()
        repacked = self.root / "radar-hub-1.2.3.tgz"
        original = Path(self.assets["radar-hub-1.2.3"])
        with tarfile.open(original) as source, tarfile.open(repacked, "w:gz") as target:
            for member in source:
                member.mtime += 3600
                target.addfile(member, source.extractfile(member))
        self.assertNotEqual(original.read_bytes(), repacked.read_bytes())
        self.state["assets"] = dict(self.assets, **{"radar-hub-1.2.3": str(repacked)})
        self.run_publisher()
        pushed = self.state["registry"]["radar-hub-1.2.3"]
        self.assertEqual(Path(pushed["archive"]).read_bytes(), repacked.read_bytes())

    def test_registry_lookup_errors_do_not_push(self):
        self.release()
        for error in ("Error: unauthorized", "Error: dial tcp: timeout", "Error: host not found"):
            with self.subTest(error=error):
                self.state["pull_failure"] = error
                self.run_publisher(succeeds=False, contains=error)
        self.assertFalse(self.calls("helm", "push"))
        self.assertFalse(self.calls("cosign", "sign"))

    def test_missing_invalid_or_multiple_digests_are_not_signed(self):
        self.release()
        for output in ("", "Digest: sha256:nope\n", "Digest: sha256:" + "b" * 64 + "\nDigest: sha256:" + "c" * 64 + "\n"):
            with self.subTest(output=output):
                self.state["digest_output"] = output
                self.run_publisher(succeeds=False, contains="exactly one valid digest")
        self.assertFalse(self.calls("cosign", "sign"))

    def test_no_matching_sha_or_draft_does_not_publish(self):
        self.release(sha="b" * 40)
        self.release(draft=True)
        self.run_publisher()
        self.assertFalse(any(event[0] in ("helm", "cosign") for event in self.state["events"]))
        self.assertFalse(self.calls("gh", "release"))

    def test_release_tag_must_resolve_to_run_commit(self):
        self.release(tag_sha="b" * 40)
        self.run_publisher(succeeds=False, contains="not this run's commit")
        self.assertFalse(self.calls("gh", "release"))
        self.assertFalse(any(event[0] in ("helm", "cosign") for event in self.state["events"]))

    def test_paginated_release_and_tag_commit_resolution(self):
        self.release(page=1)
        self.run_publisher()
        self.assertTrue(any("/commits/refs/tags/radar-hub-1.2.3" in event[2]
                            for event in self.calls("gh", "api") if len(event) > 2))
        self.assertEqual(len(self.calls("cosign", "verify")), 1)

    def test_github_api_and_asset_failure_fail_job(self):
        self.release()
        for field in ("list_failure", "download_failure"):
            with self.subTest(field=field):
                self.state[field] = True
                expected = "GitHub API unavailable" if field == "list_failure" else "Release asset unavailable"
                self.run_publisher(succeeds=False, contains=expected)
                del self.state[field]
        self.assertFalse(self.calls("helm", "push"))

    def test_prerelease_build_metadata_uses_helm_oci_tag(self):
        self.release("radar-hub-1.2.3-rc.1+build.2")
        self.run_publisher()
        self.run_publisher()
        self.assertEqual(len(self.calls("helm", "push")), 1)
        self.assertEqual(len(self.calls("cosign", "verify")), 2)


if __name__ == "__main__":
    if os.environ.get("PUBLISH_TEST_TOOL") in ("gh", "helm", "cosign", "cr"):
        fake_cli(os.environ["PUBLISH_TEST_TOOL"])
    else:
        unittest.main(verbosity=2)
