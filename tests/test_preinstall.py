import hashlib
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


class BrowserInstallTests(unittest.TestCase):
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
            release.write_text('ID="ubuntu"\n')
            packages = termlo.SystemPackages("global", tmp, termlo.uninstall.Receipt(Path(tmp)))
            with patch.object(sys, "platform", "linux"), patch.object(termlo, "OS_RELEASE", release), \
                 patch.object(native_browser, "executable", return_value=None), patch.object(native_browser, "check"), \
                 patch.object(packages, "install") as install_packages, \
                 patch("shutil.which", return_value="/usr/bin/snap"), patch.object(os, "getuid", return_value=501), \
                 patch("subprocess.run", return_value=subprocess.CompletedProcess([], 1)) as run:
                termlo.ensure_browser(packages)
        install_packages.assert_not_called()
        self.assertIn(call(["sudo", "snap", "install", "chromium"], check=True), run.call_args_list)

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
