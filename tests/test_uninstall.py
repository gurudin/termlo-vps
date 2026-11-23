"""Uninstall only in temporary homes and against mocked system package managers."""

import base64
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import browser
import pairing
import sync_agent
import termlo
import uninstall


class UninstallTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        env = patch.dict(os.environ, {"HOME": str(self.home), "XDG_CONFIG_HOME": str(self.home / "cfg"),
                                      "XDG_DATA_HOME": str(self.home / "data"),
                                      "MUTAGEN_DATA_DIRECTORY": str(self.home / "custom" / "mutagen")})
        env.start()
        self.addCleanup(env.stop)
        self.folder = termlo.config_dir()
        self.folder.mkdir(parents=True)
        self.receipt = uninstall.Receipt(self.folder)
        self.cli = self.home / ".local/bin/termlo"

    def test_authorizations_are_precise_and_other_lines_survive_byte_for_byte(self):
        ssh = self.home / ".ssh"
        ssh.mkdir()
        keys = ssh / "authorized_keys"
        blob = base64.b64encode(pairing.ED25519_PREFIX + secrets.token_bytes(32))
        ordinary = b"ssh-ed25519 " + blob + b" personal\r\n"
        kept = ordinary + b"# termlo-mac\n" + b"restrict ssh-ed25519 " + blob + b" termlo-mac\n"
        keys.write_bytes(kept)
        pairing.issue()
        issued = keys.read_bytes().splitlines(keepends=True)[-1]
        ticket = pairing.invitation_entry(issued.rstrip())[2].decode()
        pairing.redeem(ticket, "termlo-pair " + blob.decode())
        pairing.issue()
        # A custom forced command with a similar comment is someone else's entry.
        foreign = issued.replace(b" redeem ", b" unrelated-command ")
        with keys.open("ab") as stream:
            stream.write(foreign + b"# final line has no newline")
        self.assertEqual(pairing.revoke_all(), 3)
        self.assertEqual(keys.read_bytes(), kept + foreign + b"# final line has no newline")
        self.assertFalse((ssh / ".termlo-pair.lock").exists())
        self.assertEqual(pairing.revoke_all(), 0)

    def test_package_records_merge_on_retry_and_removal_spares_unrelated_packages(self):
        installed = {"git"}
        def present(kind, name, **kwargs):
            return name in installed
        with patch.object(uninstall, "package_present", side_effect=present):
            with self.assertRaises(OSError), self.receipt.observe_packages("apt", ["git", "tmux", "chromium", "curl"]):
                installed.add("tmux")
                raise OSError("package installer stopped")
            with self.receipt.observe_packages("apt", ["git", "tmux", "chromium", "curl"]):
                installed.update(["chromium", "curl"])
            state = uninstall.Receipt(self.folder)
            self.assertEqual(state.data["packages"], {"apt": ["chromium", "tmux"]})
            self.assertEqual(state.path.stat().st_mode & 0o777, 0o600)
            def remove(command, **kwargs):
                self.assertEqual(command[:3], ["sudo", "dpkg", "--remove"])
                self.assertEqual(set(command[3:]), {"tmux", "chromium"})
                installed.difference_update(command[3:])
                return subprocess.CompletedProcess(command, 0)
            with patch.object(os, "geteuid", return_value=501), patch("subprocess.run", side_effect=remove):
                uninstall.remove_packages(state)
            self.assertEqual(installed, {"git", "curl"})
            self.assertEqual(uninstall.Receipt(self.folder).data["packages"], {})

    def test_failed_package_removal_keeps_cli_and_receipt_for_retry(self):
        termlo.install_cli()
        self.receipt.data["packages"]["apt"] = ["tmux"]
        self.receipt.save()
        with patch.object(uninstall, "package_present", return_value=True), \
             patch("subprocess.run", return_value=subprocess.CompletedProcess([], 1)):
            with self.assertRaisesRegex(ValueError, "keep-tools"):
                uninstall.run(self.folder, False)
        self.assertTrue(self.cli.exists())
        self.assertTrue(self.receipt.path.exists())
        with patch("subprocess.run", side_effect=AssertionError("cannot touch packages with --keep-tools")):
            uninstall.run(self.folder, True)
        self.assertFalse(self.cli.exists())
        self.assertFalse(self.folder.exists())

    def test_mutagen_agent_ownership_and_custom_directory(self):
        target = sync_agent.installed_path()
        def install():
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b"agent")
            return target
        with patch.object(sync_agent, "install", side_effect=install):
            self.receipt.install_agent()
            self.receipt.install_agent()
        self.assertIn(str(target.resolve()), self.receipt.data["agents"])
        sibling = target.parent.parent / "0.17.0/mutagen-agent"
        sibling.parent.mkdir()
        sibling.write_bytes(b"previous agent")
        with patch.dict(os.environ, MUTAGEN_DATA_DIRECTORY=str(self.home / "unrelated")):
            uninstall.remove_agents(uninstall.Receipt(self.folder))
        self.assertFalse(target.exists())
        self.assertTrue(sibling.exists())
        install()
        self.receipt.data["agents"] = {}
        with patch.object(sync_agent, "install", return_value=target):
            self.receipt.install_agent()
        self.assertEqual(self.receipt.data["agents"], {})
        self.assertTrue(target.exists())

    def test_changed_binary_and_user_projects_are_preserved(self):
        agent = sync_agent.installed_path()
        agent.parent.mkdir(parents=True)
        agent.write_text("installer version")
        self.receipt.data["agents"][str(agent.resolve())] = uninstall.digest(agent)
        agent.write_text("replacement")
        self.receipt.save()
        self.cli.parent.mkdir(parents=True)
        self.cli.write_text("my unrelated program")
        project = self.home / "workspaces" / "project"
        project.mkdir(parents=True)
        (project / "code").write_text("keep")
        custom = self.folder / "my-notes"
        custom.write_text("keep")
        for _ in range(2):
            uninstall.run(self.folder, False)
        self.assertEqual(self.cli.read_text(), "my unrelated program")
        self.assertEqual(agent.read_text(), "replacement")
        self.assertEqual((project / "code").read_text(), "keep")
        self.assertEqual(custom.read_text(), "keep")

    def test_receipt_round_trip_for_an_agent_installed_in_a_linked_version_directory(self):
        target = sync_agent.installed_path()
        target.parent.parent.mkdir(parents=True)
        mounted = self.home / "shared volume"
        mounted.mkdir()
        target.parent.symlink_to(mounted)

        def install():
            target.write_bytes(b"owned agent")
            return target

        with patch.object(sync_agent, "install", side_effect=install):
            self.receipt.install_agent()
        restored = uninstall.Receipt(self.folder)
        self.assertIn(str(target.resolve()), restored.data["agents"])
        with patch.dict(os.environ, MUTAGEN_DATA_DIRECTORY=str(self.home / "different sync directory")):
            uninstall.remove_agents(restored)
        self.assertEqual(target.read_bytes(), b"owned agent")
        uninstall.remove_agents(restored)
        self.assertFalse(target.exists())
        self.assertTrue(mounted.is_dir())
        self.assertTrue(target.parent.is_symlink())

    def test_claude_native_updates_and_account_data(self):
        launcher = self.cli.with_name("claude")
        versions = self.home / "data/claude/versions"
        with self.receipt.observe_claude():
            launcher.parent.mkdir(parents=True)
            versions.mkdir(parents=True)
            initial = versions / "2.1.1"
            initial.write_bytes(b"initial")
            launcher.symlink_to(initial)
        updated = versions / "2.1.2"
        updated.write_bytes(b"updated")
        launcher.unlink()
        launcher.symlink_to(updated)
        settings = self.home / ".claude/settings.json"
        settings.parent.mkdir()
        settings.write_text("keep")
        uninstall.remove_claude(self.receipt.data["claude"])
        self.assertFalse(os.path.lexists(launcher))
        self.assertFalse(versions.exists())
        self.assertEqual(settings.read_text(), "keep")

    def test_claude_existing_or_replaced_launcher(self):
        launcher = self.cli.with_name("claude")
        launcher.parent.mkdir(parents=True)
        launcher.write_text("before")
        with self.receipt.observe_claude():
            launcher.write_text("updated by installer")
        self.assertNotIn("claude", self.receipt.data)
        launcher.unlink()
        with self.receipt.observe_claude():
            launcher.write_text("created")
        launcher.unlink()
        launcher.symlink_to(self.home / "some-other-cli")
        uninstall.remove_claude(self.receipt.data["claude"])
        self.assertTrue(launcher.is_symlink())

    def test_remove_only_containers_with_matching_name_owner_and_label(self):
        uid = os.getuid()
        name = f"termlo-login-{uid}-default"
        different = f"termlo-login-{uid}-11111111-2222-4333-8444-555555555555"
        listing = f"{name}\n{different}\ntermlo-login-{uid + 1}-default\nrandom\n"
        removed = []
        def run(command, **kwargs):
            if command[1] == "ps":
                self.assertIn("label=io.termlo.login", command)
                return subprocess.CompletedProcess(command, 0, listing, "")
            if command[1] == "container":
                owner = f"{uid}-default" if command[-1] == name else "someone-else"
                record = [{"Config": {"Labels": {browser.LABEL: owner}}, "Id": "managed-id"}]
                return subprocess.CompletedProcess(command, 0, json.dumps(record), "")
            removed.append(command)
            return subprocess.CompletedProcess(command, 0)
        with patch("shutil.which", side_effect=lambda tool: tool if tool == "podman" else None), \
             patch.object(browser, "available_engine", return_value="podman"), patch("subprocess.run", side_effect=run):
            browser.stop_owned_sessions(self.folder)
        self.assertEqual(removed, [["podman", "rm", "-f", "-v", "managed-id"]])

    def test_package_queries_tell_missing_from_a_failed_database(self):
        cases = [
            ("apt", "git", 1, "", "dpkg-query: no packages found matching git", False),
            ("apt", "tmux", 0, "installed", "", True),
            ("apt", "adb", 0, "half-installed", "", None),
            ("cask", "google-chrome", 0, "android-platform-tools\n", "", False),
            ("formula", "tmux", 0, "user/tap/tmux\n", "", True),
            ("snap", "chromium", 0, "Name Version\nchromium 122\n", "", True),
            ("snap", "chromium", 1, "", "No snaps are installed yet. Try 'snap install hello-world'.", False),
            ("snap", "chromium", 1, "", "cannot connect to snapd", None),
        ]
        for kind, name, status, stdout, stderr, expected in cases:
            with self.subTest(kind=kind, name=name), patch("shutil.which", return_value="tool"), \
                 patch("subprocess.run", return_value=subprocess.CompletedProcess([], status, stdout, stderr)):
                self.assertIs(uninstall.package_present(kind, name), expected)

    def test_offline_legacy_browser_can_be_cleaned_up_after_uninstall(self):
        termlo.install_cli()
        self.receipt.save()
        marker = self.folder / "browser.lock"
        marker.touch()
        with patch.object(browser, "stop_owned_sessions", side_effect=subprocess.TimeoutExpired(["docker", "info"], 8)):
            with self.assertRaisesRegex(ValueError, "在线卸载命令"):
                uninstall.run(self.folder, False)
        self.assertFalse(self.cli.exists())
        self.assertTrue(marker.exists())
        with patch.object(browser, "stop_owned_sessions", return_value=True) as stop:
            uninstall.run(self.folder, False)
        stop.assert_called_once_with(self.folder)
        self.assertFalse(self.folder.exists())

    def test_service_account_reuse_and_active_process_failure(self):
        account = Mock(pw_uid=992, pw_gid=991, pw_dir="/home/termlo-browser", pw_shell="/usr/sbin/nologin")
        with patch("pwd.getpwnam", return_value=account), self.receipt.observe_browser_user():
            pass
        self.assertNotIn("browserUser", self.receipt.data)
        with patch("pwd.getpwnam", side_effect=[KeyError(), account]), self.receipt.observe_browser_user():
            pass
        entry = self.receipt.data["browserUser"]
        self.assertEqual((entry["uid"], entry["gid"]), (992, 991))
        with patch.object(sys, "platform", "linux"), patch.object(os, "geteuid", return_value=0), \
             patch("pwd.getpwnam", return_value=account), patch("subprocess.run") as remove:
            uninstall.remove_browser_user(dict(entry, uid=999))
            remove.assert_not_called()
            remove.side_effect = subprocess.CalledProcessError(8, ["userdel"])
            with patch("os.path.lexists", return_value=False), self.assertRaises(subprocess.CalledProcessError):
                uninstall.remove_browser_user(entry)
            self.assertTrue(self.receipt.path.exists())

    def test_private_browser_home_stamp_detects_added_files_and_preserves_user_data(self):
        folder = (self.home / "browser").resolve()
        folder.mkdir()
        (folder / ".profile").write_text("skeleton")
        first = uninstall.browser_home_stamp(folder, os.getuid())
        self.assertIsNotNone(first)
        scratch = folder / "temporary-profile"
        scratch.mkdir()
        scratch.rmdir()
        self.assertEqual(uninstall.browser_home_stamp(folder, os.getuid()), first)
        (folder / "my-project").write_text("keep")
        self.assertNotEqual(uninstall.browser_home_stamp(folder, os.getuid()), first)


if __name__ == "__main__":
    unittest.main()
