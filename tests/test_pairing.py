import base64
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import secrets
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pairing


class PairingTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        home = patch.dict(os.environ, HOME=temp.name)
        home.start()
        self.addCleanup(home.stop)
        self.keys = Path(temp.name) / ".ssh/authorized_keys"
        self.keys.parent.mkdir()
        self.existing = b"# existing account configuration\n# keep even without a trailing newline"
        self.keys.write_bytes(self.existing)

    def issue(self):
        invite = pairing.issue()
        record = self.keys.read_bytes().splitlines()[-1]
        self.assertIn(b'restrict,expiry-time="', record)
        self.assertIn(b'command="', record)
        self.assertFalse(invite["key"].encode() in record)
        return invite, pairing.invitation_entry(record)[2].decode()

    @staticmethod
    def request():
        return "termlo-pair " + base64.b64encode(pairing.ED25519_PREFIX + secrets.token_bytes(32)).decode()

    def test_only_one_mac_is_enrolled_even_with_concurrent_redemption(self):
        _, ticket = self.issue()
        requests = [self.request(), self.request()]
        def redeem(request):
            try:
                return pairing.redeem(ticket, request)
            except ValueError:
                return None
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(redeem, requests))
        self.assertCountEqual(results, [pairing.RECEIPT, None])
        winner = requests[results.index(pairing.RECEIPT)].split()[1]
        keys = self.keys.read_bytes()
        self.assertTrue(keys.startswith(self.existing + b"\n"))
        self.assertIn(b" termlo-spent:" + ticket.encode(), keys)
        self.assertTrue(keys.endswith(b"\nssh-ed25519 " + winner.encode() + b" termlo-mac\n"))
        with self.assertRaises(ValueError):
            pairing.redeem(ticket, requests[0])
        _, fresh = self.issue()
        pairing.redeem(fresh, "termlo-pair " + winner)
        self.assertEqual(self.keys.read_bytes().count(b" termlo-mac\n"), 1)

    def test_expiration_and_invalid_requests_cannot_authorize_a_device(self):
        invite, ticket = self.issue()
        contents = self.keys.read_bytes()
        for request in ["", "echo test", self.request() + "\nextra", "termlo-pair " + "A" * 68]:
            with self.assertRaises(ValueError):
                pairing.redeem(ticket, request)
            self.assertEqual(self.keys.read_bytes(), contents)
        with patch.object(pairing.time, "time", return_value=invite["expiresAt"]):
            with self.assertRaisesRegex(ValueError, "过期"):
                pairing.redeem(ticket, self.request())
            pairing.issue()
        self.assertNotIn(ticket.encode(), self.keys.read_bytes())
        self.assertTrue(self.keys.read_bytes().startswith(self.existing))

    def test_expiry_cleanup_preserves_key_lines_with_custom_commands(self):
        invite, _ = self.issue()
        issued = self.keys.read_bytes().splitlines(keepends=True)[-1]
        custom = issued.replace(b" redeem ", b" my-command ")
        with self.keys.open("ab") as stream:
            stream.write(custom)
        with patch.object(pairing.time, "time", return_value=invite["expiresAt"]):
            pairing.issue()
        lines = self.keys.read_bytes().splitlines(keepends=True)
        self.assertIn(custom, lines)
        self.assertNotIn(issued, lines)

    def test_expired_utc_and_legacy_entries_are_removed_together(self):
        legacy, old_ticket = self.issue()
        with pairing.locked_authorized_keys() as keys, pairing.pending_invitation(keys, utc_expiry=True) as modern:
            expiry = max(legacy["expiresAt"], modern["expiresAt"])
        current = self.keys.read_bytes().splitlines(keepends=True)[-1]
        modern_ticket = pairing.invitation_entry(current)[2].decode()
        self.assertIn(b'Z",command=', current)
        other = current.replace(b" redeem ", b" unrelated ")
        with self.keys.open("ab") as stream:
            stream.write(other)
        with patch.object(pairing.time, "time", return_value=expiry):
            for ticket in (old_ticket, modern_ticket):
                with self.assertRaisesRegex(ValueError, "过期"):
                    pairing.redeem(ticket, self.request())
            pairing.issue()
        lines = self.keys.read_bytes().splitlines(keepends=True)
        self.assertNotIn(current, lines)
        self.assertNotIn(old_ticket.encode(), b"".join(lines))
        self.assertIn(other, lines)
