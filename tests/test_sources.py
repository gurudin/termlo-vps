import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from test_vps import ROOT, command
import browser
import termlo
import wizard


class SourceTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.folder = Path(temp.name)
        self.script = str(ROOT / "sources.sh")
        self.log = self.folder / "events"
        self.release = self.folder / "os-release"
        self.release.write_text('ID=ubuntu\nVERSION_CODENAME="jammy"\n')
        self.env = dict(PATH=f"{self.folder}:/usr/bin:/bin", LOG=str(self.log), ARCH="arm64")
        command(self.folder / "sudo", 'exec "$@"')
        command(self.folder / "dpkg", 'echo "$ARCH"')
        command(self.folder / "curl", '''
for url do :; done
echo "$url" >> "$LOG"
case "$url" in
    *cdn-cgi/trace) printf '%s\\n' "${TRACE:-}" ;;
    https://myip.ipip.net) printf '%s\\n' "${IPIP:-}" ;;
    *) exit 1 ;;
esac''')
        command(self.folder / "apt-get", '''
route=system
case " $* " in *Dir::Etc::sourcelist=*) route=cn ;; esac
phase=install
case " $* " in *" update "*) phase=index ;; *" --download-only "*) phase=download ;; esac
echo "$route $phase" >> "$LOG"
test "${FAIL:-}" != "$route $phase"''')

    def detect(self, trace, ipip=""):
        return subprocess.check_output(["bash", self.script, "detect"],
                                       env=dict(self.env, TRACE=trace, IPIP=ipip), text=True).strip()

    def apt(self, region, **overrides):
        # Supply an OS-release fixture to the same function used by the python-free bootstrap.
        return subprocess.run(["bash", "-c", '. "$1"; install_packages "$2" "$3" "$4" tmux', "test",
                               self.script, str(self.release), region, str(self.folder)],
                              env=dict(self.env, **overrides), capture_output=True, text=True)

    def test_region_from_vps_exit_and_fallback_when_trace_is_unavailable(self):
        for country, channel in (("CN", "cn"), ("US", "global"), ("HK", "global")):
            self.assertEqual(self.detect(f"ip=8.8.8.8\r\nloc={country}\r"), channel + " 8.8.8.8")
        self.assertNotIn("myip.ipip.net", self.log.read_text())
        prefix = "当前 IP：1.2.3.4  来自于："
        self.assertEqual(self.detect("<html>error</html>", prefix + "中国 广东 电信"), "cn 1.2.3.4")
        self.assertEqual(self.detect("loc=XX", prefix + "中国 香港"), "global 1.2.3.4")
        self.assertEqual(self.detect("", "<html>error</html>"), "auto")

    def test_china_sources_cover_ubuntu_ports_amd64_and_debian_security(self):
        for distro, suite, arch, repo, security in (
            ("ubuntu", "jammy", "arm64", "ubuntu-ports", "ubuntu-ports"),
            ("ubuntu", "noble", "amd64", "ubuntu", "ubuntu"),
            ("debian", "bookworm", "amd64", "debian", "debian-security"),
        ):
            with self.subTest(distro=distro, arch=arch):
                self.release.write_text(f'ID={distro}\nVERSION_CODENAME="{suite}"\n')
                result = self.apt("cn", ARCH=arch)
                self.assertEqual(result.returncode, 0, result.stderr)
                source = (self.folder / "termlo.list").read_text()
                self.assertIn(f"signed-by=/usr/share/keyrings/{distro}-archive-keyring.gpg", source)
                self.assertIn(f"{repo} {suite}-updates ", source)
                self.assertIn(f"{security} {suite}-security ", source)
        self.assertNotIn("system", self.log.read_text())

    def test_index_failure_moves_to_the_other_source_before_downloading(self):
        self.assertEqual(self.apt("cn", FAIL="cn index").returncode, 0)
        self.assertEqual(self.log.read_text().splitlines(), ["cn index", "system index", "system download", "system install"])

    def test_preflight_download_uses_the_signed_fallback_without_installing(self):
        command(self.folder / "apt-get", '''
route=system
for arg do
    case "$arg" in Dir::Etc::sourcelist=*) route=cn ;; Dir::Cache::archives=*) archives=${arg#*=} ;; esac
done
case " $* " in
    *" update "*) echo "$route index" >> "$LOG" ;;
    *" --download-only "*)
        echo "$route download" >> "$LOG"
        [ "$route" = cn ] && echo package > "$archives/tmux_1_arm64.deb" ;;
    *) exit 100 ;;
esac''')
        check = subprocess.run(["sh", "-ec", '. "$1"; . "$2"; release=$3; scratch=$4; apt_packages_available tmux',
                                "check", str(ROOT / "prerequisites.sh"), str(ROOT / "doctor.sh"),
                                str(self.release), str(self.folder)], env=self.env, capture_output=True, text=True)
        self.assertEqual(check.returncode, 0, check.stderr)
        self.assertEqual(self.log.read_text().splitlines(), ["system index", "system download", "cn index", "cn download"])
        self.assertIn("signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg",
                      (self.folder / "apt-cn/sources.list").read_text())

    def test_download_failure_falls_back_and_remembers_working_source(self):
        self.assertEqual(self.apt("cn", FAIL="cn download").returncode, 0)
        self.assertEqual(self.apt("cn").returncode, 0)
        self.assertEqual(self.log.read_text().splitlines(), ["cn index", "cn download", "system index",
                         "system download", "system install", "system download", "system install"])
        self.assertEqual(self.apt("auto", FAIL="system download").returncode, 0)
        self.assertEqual(self.log.read_text().splitlines()[-4:], ["system download", "cn index",
                                                                  "cn download", "cn install"])

    def test_overseas_and_unknown_use_system_first_and_leave_dpkg_errors_visible(self):
        self.assertNotEqual(self.apt("global", FAIL="system install").returncode, 0)
        self.assertEqual(self.log.read_text().splitlines(), ["system index", "system download", "system install"])
        self.log.write_text("")
        self.assertEqual(self.apt("auto").returncode, 0)
        self.assertEqual(self.log.read_text().splitlines(), ["system download", "system install"])

    def test_missing_or_unsupported_os_release_uses_configured_sources(self):
        self.release.unlink()
        self.assertEqual(self.apt("cn").returncode, 0)
        self.assertNotIn("cn", self.log.read_text())

    def test_detected_address_is_validated_and_reused_only_after_local_addresses(self):
        with patch.dict(os.environ, TERMLO_INSTALL_NETWORK="cn 8.8.8.8"), \
             patch.object(wizard, "local_addresses", return_value=[]), \
             patch.object(wizard, "public_egress_address", side_effect=AssertionError("extra lookup")):
            region, ip = termlo.install_network()
            self.assertEqual(wizard.suggest_host(None, region, ip)[0], "8.8.8.8")
            public = termlo.ipaddress.ip_address("1.1.1.1")
            self.assertEqual(wizard.suggest_host(public, region, ip)[0], "1.1.1.1")
        for bad in ("127.0.0.1", "bad-data", "10.2.3.4"):
            with patch.dict(os.environ, TERMLO_INSTALL_NETWORK="cn " + bad):
                self.assertEqual(termlo.install_network(), ("cn", None))

    def test_mainland_public_address_provider_falls_back_after_invalid_data(self):
        with patch("urllib.request.urlopen", side_effect=[io.BytesIO(b"{}"), io.BytesIO(b"8.8.8.8")]) as fetch:
            self.assertEqual(wizard.public_egress_address("cn"), "8.8.8.8")
        self.assertEqual([call.args[0] for call in fetch.call_args_list],
                         ["https://myip.ipip.net/json", "https://api64.ipify.org"])

    def test_chromium_pull_order_digest_and_reuse(self):
        for region, first, fallback in (("cn", browser.CN_IMAGE, browser.IMAGE),
                                        ("global", browser.IMAGE, browser.CN_IMAGE)):
            with patch.object(browser, "local_image", return_value=None), \
                 patch("subprocess.run", side_effect=[subprocess.CompletedProcess([], 1),
                                                      subprocess.CompletedProcess([], 0)]) as run:
                browser.prepare_image("docker", region)
                self.assertEqual([call.args[0][-1] for call in run.call_args_list], [first, fallback])
                self.assertEqual(first.split("@")[1], fallback.split("@")[1])
        for cache in (browser.CN_IMAGE, browser.LEGACY_IMAGE):
            def inspect(args, **kwargs):
                self.assertEqual(args[1:3], ["image", "inspect"])
                return subprocess.CompletedProcess(args, 0 if args[-1] == cache else 1)
            with patch("subprocess.run", side_effect=inspect):
                self.assertEqual(browser.local_image("docker"), cache)
                browser.prepare_image("docker", "global")
