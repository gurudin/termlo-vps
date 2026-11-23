import hashlib
from contextlib import nullcontext
import io
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import Mock, call, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import native_browser
import sync_agent
import termlo


def archive_member(tar, name, data):
    member = tarfile.TarInfo(name)
    member.size = len(data)
    tar.addfile(member, io.BytesIO(data))


class RemoteAgentTests(unittest.TestCase):
    def test_verified_agent_from_bundle_reuse_and_failed_update(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            package = folder / "release.tar.gz"
            payload = b"#!/bin/sh\n[ \"$1\" = version ] && echo 0.18.1\n"
            nested = io.BytesIO()
            with tarfile.open(fileobj=nested, mode="w:gz") as agents:
                archive_member(agents, "linux_amd64", payload)
            with tarfile.open(package, mode="w:gz") as release:
                archive_member(release, "mutagen-agents.tar.gz", nested.getvalue())
            digest = hashlib.sha256(package.read_bytes()).hexdigest()
            env = {"MUTAGEN_DATA_DIRECTORY": str(folder / "data"), "TERMLO_MUTAGEN_ARCHIVE": str(package)}
            with patch.dict(os.environ, env), patch.object(sys, "platform", "linux"), \
                 patch.object(sync_agent.platform, "machine", return_value="x86_64"), \
                 patch.dict(sync_agent.RELEASES, linux_amd64=(1234, digest)):
                target = sync_agent.install()
                self.assertEqual(target.read_bytes(), payload)
                self.assertEqual(target.stat().st_mode & 0o777, 0o700)
                package.write_bytes(b"bad archive")
                self.assertEqual(sync_agent.install(), target)
                target.write_text("#!/bin/sh\necho old\n")
                with self.assertRaisesRegex(ValueError, "校验失败"):
                    sync_agent.install()
                self.assertIn("echo old", target.read_text())
                self.assertEqual(list(target.parent.iterdir()), [target])


class DownloadTrustTests(unittest.TestCase):
    def setUp(self):
        self.packages = termlo.SystemPackages("global", "", None)

    def test_success_does_not_require_a_specific_ca_file(self):
        with patch.dict(os.environ, {"CURL_CA_BUNDLE": "/a/platform/specific/bundle"}), \
             patch.object(self.packages, "install") as install:
            self.assertEqual(self.packages.with_https_repair(lambda: "downloaded"), "downloaded")
            install.assert_not_called()

    def test_unreadable_system_store_is_repaired_once_then_retried(self):
        download = Mock(side_effect=[subprocess.CalledProcessError(77, ["curl"]), "ok"])
        with patch.dict(os.environ, {}, clear=True), patch.object(sys, "platform", "linux"), \
             patch.object(self.packages, "install") as install:
            self.assertEqual(self.packages.with_https_repair(download), "ok")
            install.assert_called_once_with(["ca-certificates"])
            self.assertEqual(download.call_count, 2)
            with self.assertRaises(subprocess.CalledProcessError):
                self.packages.with_https_repair(Mock(side_effect=subprocess.CalledProcessError(77, ["curl"])))
            install.assert_called_once()

    def test_reset_custom_ca_and_untrusted_peer_do_not_change_system_trust(self):
        with patch.object(sys, "platform", "linux"), patch.object(self.packages, "install") as install, \
             patch("ssl.create_default_context") as trust:
            trust.return_value.get_ca_certs.return_value = [{}]
            for status, env, error in [(35, {}, subprocess.CalledProcessError), (60, {}, ValueError),
                                       (77, {"CURL_CA_BUNDLE": "/custom"}, ValueError)]:
                with self.subTest(status=status), patch.dict(os.environ, env, clear=True), self.assertRaises(error):
                    self.packages.with_https_repair(Mock(side_effect=subprocess.CalledProcessError(status, ["curl"])))
            install.assert_not_called()


class ToolPathTests(unittest.TestCase):
    def test_a_link_to_the_package_binary_can_be_repaired_but_a_separate_file_cannot(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            system = home / "system-bin"
            user = home / ".local/bin"
            system.mkdir()
            user.mkdir(parents=True)
            binary = system / "tmux"
            binary.write_text("#!/bin/sh\nexit 1\n")
            binary.chmod(0o755)
            link = user / "tmux"
            link.symlink_to(binary)
            with patch.dict(os.environ, HOME=tmp, PATH=f"{user}:{system}"), patch.object(os, "defpath", str(system)):
                self.assertEqual(termlo.base_tool_state(["tmux", "-V"]), "repair")
                link.unlink()
                os.link(binary, link)
                self.assertEqual(termlo.base_tool_state(["tmux", "-V"]), "override")

    def test_mac_cli_uses_the_same_homebrew_precedence_on_repeated_entry(self):
        with patch.dict(os.environ, HOME="/test-home", PATH="/usr/bin:/bin"), patch.object(sys, "platform", "darwin"):
            expected = ["/test-home/.local/bin", "/test-home/.npm-global/bin", "/opt/homebrew/bin",
                        "/usr/local/bin", "/usr/bin", "/bin"]
            for _ in range(2):
                termlo.add_tool_paths()
                self.assertEqual(os.get_exec_path(), expected)


class BrowserInstallTests(unittest.TestCase):
    def test_disposable_mac_render_uses_the_mock_keychain(self):
        with tempfile.TemporaryDirectory() as home:
            folder = Path(home)
            browser = folder / "Test Browser"
            browser.write_text("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$HOME/arguments\"\n"
                               "echo '<title>termlo-browser-ready</title>'\n")
            browser.chmod(0o700)
            for platform in ("darwin", "linux"):
                with self.subTest(platform=platform), patch.dict(os.environ, HOME=home), \
                     patch.object(sys, "platform", platform), patch.object(os, "geteuid", return_value=501), \
                     patch.object(native_browser, "candidates", return_value=[str(browser)]):
                    for check in (native_browser.check_for_install, native_browser.check):
                        self.assertEqual(check(), str(browser))
                        arguments = (folder / "arguments").read_text().splitlines()
                        self.assertEqual("--use-mock-keychain" in arguments, platform == "darwin")
                        self.assertIn("--headless", arguments)
                        profile, = [arg.split("=", 1)[1] for arg in arguments if arg.startswith("--user-data-dir=")]
                        self.assertEqual(Path(profile).parent, folder)
                        self.assertFalse(Path(profile).exists())

    def test_remote_mac_installs_native_browser_and_platform_tools_with_homebrew(self):
        packages = Mock()
        with patch.object(sys, "platform", "darwin"), patch("shutil.which", return_value=None), \
             patch.object(native_browser, "executable", return_value=None), patch.object(native_browser, "check") as check, \
             patch("subprocess.run"):
            termlo.ensure_base_tools(packages)
        packages.install.assert_called_once_with(["git", "tmux"])
        self.assertEqual(packages.cask.call_args_list, [call("android-platform-tools"), call("google-chrome")])
        check.assert_called_once_with(prepare_root=True)

    def test_ubuntu_uses_installed_snap_service_for_a_missing_browser(self):
        with tempfile.TemporaryDirectory() as tmp:
            release = Path(tmp) / "os-release"
            release.write_text('ID="ubuntu" # distribution\n')
            packages = termlo.SystemPackages("global", tmp, termlo.uninstall.Receipt(Path(tmp)))
            original_run = subprocess.run
            def run_command(args, **kwargs):
                if args[0] == "/bin/sh":
                    return original_run(args, **kwargs)
                return subprocess.CompletedProcess(args, 0, stdout="", stderr="")
            with patch.object(sys, "platform", "linux"), patch.object(termlo, "OS_RELEASE", release), \
                 patch.object(native_browser, "executable", return_value=None), patch.object(native_browser, "check"), \
                 patch.object(packages, "install") as install_packages, \
                 patch("shutil.which", return_value="/usr/bin/snap"), patch.object(os, "getuid", return_value=501), \
                 patch("subprocess.run", side_effect=run_command) as run:
                termlo.ensure_browser(packages)
        install_packages.assert_not_called()
        self.assertIn(call(["sudo", "snap", "install", "chromium"], stdout=sys.stderr, check=True), run.call_args_list)
        self.assertIn(call(["sudo", "snap", "wait", "system", "seed.loaded"], stdout=sys.stderr, timeout=240, check=True),
                      run.call_args_list)

    def test_ubuntu_snap_stub_is_ignored_and_root_preflight_defers_snap_probe(self):
        with tempfile.TemporaryDirectory() as tmp:
            stub = Path(tmp) / "chromium-browser"
            stub.write_text("#!/bin/sh\necho 'Requires the chromium snap: snap install chromium'\nexit 1\n")
            stub.chmod(0o755)
            with patch.object(sys, "platform", "linux"), \
                 patch("shutil.which", side_effect=lambda name: str(stub) if name == "chromium-browser" else None), \
                 patch("os.access", return_value=False):
                self.assertIsNone(native_browser.executable())
            with patch.object(sys, "platform", "linux"), patch.object(os, "geteuid", return_value=0), \
                 patch("pwd.getpwnam", side_effect=KeyError), \
                 patch("shutil.which", return_value=None), \
                 patch("os.access", side_effect=lambda p, mode: p == "/snap/bin/chromium"):
                with self.assertRaises(native_browser.SnapProbeDeferred) as deferred:
                    native_browser.check_for_install()
                self.assertEqual(str(deferred.exception), "/snap/bin/chromium")

    def test_mac_git_stub_checks_xcode_select_before_running_git(self):
        with patch.object(sys, "platform", "darwin"), patch("shutil.which", return_value="/usr/bin/git"), \
             patch("subprocess.run", return_value=subprocess.CompletedProcess([], 2)) as run:
            self.assertFalse(termlo.tool_works(["git", "--version"]))
        run.assert_called_once()
        self.assertEqual(run.call_args.args[0], ["/usr/bin/xcode-select", "-p"])

    def test_ubuntu_repairs_unusable_snap_cli_and_checks_the_stable_architecture(self):
        packages = Mock()
        with patch.object(sys, "platform", "linux"), patch.object(os, "geteuid", return_value=501), \
             patch.object(termlo, "shell_helper", return_value=subprocess.CompletedProcess([], 0)), \
             patch.object(native_browser, "executable", return_value=None), patch.object(native_browser, "check"), \
             patch.object(termlo, "tool_works", side_effect=[False, True, False, False]):
            termlo.ensure_browser(packages)
            with self.assertRaisesRegex(ValueError, "snap --version"):
                termlo.ensure_browser(packages)
        self.assertEqual(packages.install.call_args_list, [call(["snapd"]), call(["snapd"])])
        packages.install_chromium_snap.assert_called_once()
        metadata = {"name": "chromium", "channel-map": []}
        for arch, risk in (("amd64", "stable"), ("arm64", "beta")):
            metadata["channel-map"].append({"channel": {"architecture": arch, "risk": risk, "track": "latest"},
                                            "download": {"url": "https://example.org/chromium.snap"}})
        self.assertTrue(native_browser.stable_chromium_snap(metadata, "amd64"))
        self.assertFalse(native_browser.stable_chromium_snap(metadata, "arm64"))

    def test_existing_browser_account_needs_no_useradd_and_group_collision_is_reported(self):
        account = Mock(pw_uid=101, pw_gid=101, pw_dir="/home/termlo-browser", pw_shell="/bin/false")
        packages = Mock()
        packages.receipt.observe_browser_user.return_value = nullcontext()
        with patch.object(sys, "platform", "linux"), patch.object(os, "geteuid", return_value=0), \
             patch("pwd.getpwnam", return_value=account), patch("shutil.which", side_effect=lambda name: name if name == "runuser" else None), \
             patch.object(native_browser, "executable", return_value="/usr/bin/chromium"), patch.object(native_browser, "check"):
            termlo.ensure_browser(packages)
        packages.install.assert_not_called()
        with patch.object(sys, "platform", "linux"), patch.object(os, "geteuid", return_value=0), \
             patch("pwd.getpwnam", side_effect=KeyError), patch("grp.getgrnam", return_value=object()):
            with self.assertRaisesRegex(ValueError, "同名专用组"):
                native_browser.check_install_account()

    def test_root_browser_probe_uses_only_the_dedicated_unprivileged_account(self):
        process = Mock(returncode=0)
        process.communicate.return_value = ("<title>termlo-browser-ready</title>", "")
        account = Mock(pw_name="termlo-browser", pw_dir="/home/termlo-browser")
        with patch.object(sys, "platform", "linux"), patch.object(os, "geteuid", return_value=0), \
             patch.object(native_browser, "root_browser_account", return_value=account) as user, \
             patch("subprocess.Popen", return_value=process) as launch:
            native_browser.check("/usr/bin/chromium", prepare_root=True)
        user.assert_called_once_with(True)
        args = launch.call_args.args[0]
        self.assertEqual(args[:6], ["runuser", "-u", "termlo-browser", "--", "env", "-i"])
        self.assertNotIn("--no-sandbox", " ".join(args))


if __name__ == "__main__":
    unittest.main()
