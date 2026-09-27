"""Offline regression tests: a strict fake aws executable replaces all AWS calls."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "projects/02-ec2-web-server/handson/cleanup.sh"
BASH = os.environ.get("BASH_EXE") or shutil.which("bash")
ACTIONS = [
    "describe-addresses", "disassociate-address", "release-address",
    "terminate-instances", "wait", "delete-security-group",
    "disassociate-route-table", "delete-route-table", "detach-internet-gateway",
    "delete-internet-gateway", "delete-subnet", "delete-vpc", "delete-key-pair",
]
MOCK = r'''#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == sts && "$2" == get-caller-identity ]]; then
  echo "${MOCK_ACCOUNT_ID:-111111111111}"
  exit 0
fi
[[ "$1" == ec2 ]] || exit 97
action="$2"
printf '%s\n' "$*" >> aws-calls.log
case "$action" in
  describe-addresses|release-address) absent=InvalidAllocationID.NotFound ;;
  disassociate-address|disassociate-route-table) absent=InvalidAssociationID.NotFound ;;
  terminate-instances|wait) absent=InvalidInstanceID.NotFound ;;
  delete-security-group) absent=InvalidGroup.NotFound ;;
  delete-route-table) absent=InvalidRouteTableID.NotFound ;;
  detach-internet-gateway) absent=Gateway.NotAttached ;;
  delete-internet-gateway) absent=InvalidInternetGatewayID.NotFound ;;
  delete-subnet) absent=InvalidSubnetID.NotFound ;;
  delete-vpc) absent=InvalidVpcID.NotFound ;;
  delete-key-pair) absent=InvalidKeyPair.NotFound ;;
  *) echo 'Unexpected AWS action' >&2; exit 97 ;;
esac
fail() {
  printf 'An error occurred (%s) when calling the Mock operation: mock failure\n' "$1" >&2
  exit 255
}
if [[ "$action" == "${FAIL_ACTION:-}" ]]; then
  if [[ "${FAIL_CODE:-}" == waiter ]]; then
    echo 'Waiter InstanceTerminated failed: Max attempts exceeded' >&2
    exit 255
  elif [[ "${FAIL_CODE:-}" == unstructured ]]; then
    echo 'Network timeout; cached text InvalidGroup.NotFound' >&2
    exit 255
  fi
  fail "${FAIL_CODE:-DependencyViolation}"
fi
if [[ "${MODE:-}" == absent ]]; then fail "$absent"; fi
if [[ "${MODE:-}" == retry ]]; then
  if [[ "$action" == delete-security-group && ! -f sg-failed-once ]]; then
    touch sg-failed-once
    fail DependencyViolation
  fi
  if [[ -f "done-$action" ]]; then fail "$absent"; fi
  touch "done-$action"
fi
if [[ "$action" == describe-addresses ]]; then
  printf '%s\n' "${ASSOCIATION:-eipassoc-test}"
fi
'''


@unittest.skipUnless(BASH, "Bash is required; set BASH_EXE on Windows")
class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ec2-cleanup-")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        (self.path / "bin").mkdir()
        # Normalize checkout CRLF for Git Bash as well as Linux CI.
        (self.path / "cleanup.sh").write_text(SOURCE.read_text(encoding="utf-8"), encoding="utf-8", newline="\n")
        mock = self.path / "bin/aws"
        mock.write_text(MOCK, encoding="utf-8", newline="\n")
        mock.chmod(0o755)
        self.state = self.path / ".handson-state.env"
        self.pem = self.path / "handson-key.pem"
        self.pem.write_text("mock key, not a credential", encoding="utf-8")
        self.state.write_text(
            'REGION="us-west-2"\nACCOUNT_ID="111111111111"\nALLOC_ID="eipalloc-test"\nINSTANCE_ID="i-test"\n'
            'SG_ID="sg-test"\nRTB_ASSOC_ID="rtbassoc-test"\nRTB_ID="rtb-test"\n'
            'IGW_ID="igw-test"\nSUBNET_ID="subnet-test"\nVPC_ID="vpc-test"\n'
            'KEY_NAME="handson-key"\nPEM_FILE="${SCRIPT_DIR}/handson-key.pem"\n',
            encoding="utf-8", newline="\n",
        )
        self.initial_state = self.state.read_bytes()

    def run_cleanup(self, **settings):
        env = os.environ.copy()
        for name in ("FAIL_ACTION", "FAIL_CODE", "MODE", "ASSOCIATION", "BASH_ENV", "ENV", "MOCK_ACCOUNT_ID"):
            env.pop(name, None)
        env.update(settings)
        env.update(AWS_EC2_METADATA_DISABLED="true", AWS_CONFIG_FILE="nonexistent-config",
                   AWS_SHARED_CREDENTIALS_FILE="nonexistent-credentials")
        return subprocess.run(
            [BASH, "--noprofile", "--norc", "-c",
             'export PATH="$PWD/bin:$PATH"; exec bash ./cleanup.sh'],
            cwd=self.path, env=env, capture_output=True, text=True, encoding="utf-8", timeout=20,
        )

    def actions(self):
        log = self.path / "aws-calls.log"
        return [line.split()[1] for line in log.read_text().splitlines()] if log.exists() else []

    def assert_preserved(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.state.read_bytes(), self.initial_state)
        self.assertTrue(self.pem.exists())
        self.assertNotIn("削除API処理を確認しました", result.stdout)

    def test_success_waits_and_uses_recorded_region(self):
        result = self.run_cleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.actions(), ACTIONS)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.pem.exists())
        for line in (self.path / "aws-calls.log").read_text().splitlines():
            self.assertIn("--region us-west-2", line)

    def test_every_aws_failure_preserves_exact_state_and_key(self):
        for action in ACTIONS:
            with self.subTest(action=action):
                result = self.run_cleanup(FAIL_ACTION=action)
                self.assert_preserved(result)
                self.assertIn("削除未完了", result.stderr)
                self.assertIn("DependencyViolation", result.stderr)

    def test_failed_address_lookup_does_not_release_address(self):
        self.assert_preserved(self.run_cleanup(FAIL_ACTION="describe-addresses", FAIL_CODE="UnauthorizedOperation"))
        self.assertNotIn("release-address", self.actions())
        self.assertNotIn("disassociate-address", self.actions())
        self.assertIn("delete-vpc", self.actions())

    def test_waiter_timeout_is_failure(self):
        self.assert_preserved(self.run_cleanup(FAIL_ACTION="wait", FAIL_CODE="waiter"))

    def test_already_absent_resources_can_complete(self):
        result = self.run_cleanup(MODE="absent")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("wait", self.actions())
        self.assertNotIn("release-address", self.actions())
        self.assertFalse(self.state.exists())

    def test_retry_after_partial_success(self):
        self.assert_preserved(self.run_cleanup(MODE="retry"))
        result = self.run_cleanup(MODE="retry")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.pem.exists())

    def test_similar_or_wrong_notfound_codes_are_failures(self):
        for code in ("InvalidGroup.NotFoundExtra", "InvalidVpcID.NotFound", "unstructured"):
            with self.subTest(code=code):
                self.assert_preserved(self.run_cleanup(FAIL_ACTION="delete-security-group", FAIL_CODE=code))

    def test_unassociated_address_skips_disassociation(self):
        result = self.run_cleanup(ASSOCIATION="None")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("disassociate-address", self.actions())
        self.assertIn("release-address", self.actions())

    def test_missing_state_never_calls_aws(self):
        self.state.unlink()
        result = self.run_cleanup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.actions(), [])

    def test_local_key_delete_failure_retains_state(self):
        mock_rm = self.path / "bin/rm"
        mock_rm.write_text("#!/usr/bin/env bash\necho 'mock local removal failure' >&2\nexit 1\n", encoding="utf-8", newline="\n")
        mock_rm.chmod(0o755)
        self.assert_preserved(self.run_cleanup())

    def test_wrong_account_never_deletes_resources_or_local_files(self):
        self.assert_preserved(self.run_cleanup(MOCK_ACCOUNT_ID="222222222222"))
        self.assertEqual(self.actions(), [])

    def test_legacy_state_without_account_refuses_deletion(self):
        self.state.write_text(self.state.read_text(encoding="utf-8").replace('ACCOUNT_ID="111111111111"\n', ''), encoding="utf-8", newline="\n")
        self.initial_state = self.state.read_bytes()
        self.assert_preserved(self.run_cleanup())
        self.assertEqual(self.actions(), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
