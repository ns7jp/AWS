"""Prove a failed build cannot enroll another run's SSH key for cleanup.

Every AWS call is replaced by a strict fake. These are regression checks,
not evidence of an actual AWS deployment.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "projects/02-ec2-web-server/handson"
BASH = os.environ.get("BASH_EXE") or shutil.which("bash")
MOCK = r'''#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == --version ]]; then echo aws-cli/2.0.0-mock; exit 0; fi
printf '%s\n' "$*" >> aws-calls.log
if [[ "$1" == sts && "$2" == get-caller-identity ]]; then
  echo "${MOCK_ACCOUNT_ID:-111111111111}"
  exit 0
fi
[[ "$1" == ec2 || "$1" == ssm ]] || exit 97
case "$2" in
  create-vpc) echo vpc-test ;;
  create-subnet) echo subnet-test ;;
  create-internet-gateway) echo igw-test ;;
  create-route-table) echo rtb-test ;;
  associate-route-table) echo rtbassoc-test ;;
  create-security-group) echo sg-test ;;
  create-key-pair)
    if [[ "${DUPLICATE_KEY:-}" == 1 ]]; then
      echo 'An error occurred (InvalidKeyPair.Duplicate) when calling the CreateKeyPair operation: existing key' >&2
      exit 255
    fi
    echo 'mock private key, not a credential'
    ;;
  get-parameters) echo ami-test ;;
  run-instances) echo i-test ;;
  allocate-address) echo eipalloc-test ;;
  describe-addresses) echo None ;;
  modify-vpc-attribute|modify-subnet-attribute|attach-internet-gateway|create-route|authorize-security-group-ingress|wait|associate-address|release-address|terminate-instances|delete-security-group|disassociate-route-table|delete-route-table|detach-internet-gateway|delete-internet-gateway|delete-subnet|delete-vpc|delete-key-pair) ;;
  *) echo "Unexpected AWS action: $2" >&2; exit 97 ;;
esac
'''


@unittest.skipUnless(BASH, "Bash is required; set BASH_EXE on Windows")
class BuildOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ec2-key-ownership-")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        (self.path / "bin").mkdir()
        for name in ("build.sh", "cleanup.sh"):
            (self.path / name).write_text((SOURCE / name).read_text(encoding="utf-8"), encoding="utf-8", newline="\n")
        mock = self.path / "bin/aws"
        mock.write_text(MOCK, encoding="utf-8", newline="\n")
        mock.chmod(0o755)
        self.state = self.path / ".handson-state.env"
        self.pem = self.path / "handson-key.pem"

    def run_script(self, name, **settings):
        env = os.environ.copy()
        for key in ("BASH_ENV", "ENV", "DUPLICATE_KEY", "MOCK_ACCOUNT_ID", "REGION", "AZ"):
            env.pop(key, None)
        env.update(MY_IP="198.51.100.10", EXPECTED_ACCOUNT_ID="111111111111", AWS_EC2_METADATA_DISABLED="true",
                   AWS_CONFIG_FILE="nonexistent-config", AWS_SHARED_CREDENTIALS_FILE="nonexistent-credentials")
        env.update(settings)
        return subprocess.run(
            [BASH, "--noprofile", "--norc", "-c",
             'export PATH="$PWD/bin:$PATH"; exec bash "$1"', "ownership-test", "./" + name],
            cwd=self.path, env=env, capture_output=True, text=True, encoding="utf-8", timeout=20,
        )

    def actions(self):
        log = self.path / "aws-calls.log"
        return [line.split()[1] for line in log.read_text().splitlines() if line.startswith("ec2 ")] if log.exists() else []

    def test_duplicate_remote_key_is_never_deleted_after_failed_build(self):
        result = self.run_script("build.sh", DUPLICATE_KEY="1")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("InvalidKeyPair.Duplicate", result.stderr)
        self.assertTrue(self.state.exists())
        self.assertFalse(self.pem.exists())
        self.assertNotIn('KEY_NAME=', self.state.read_text(encoding="utf-8"))
        unrelated_key = self.path / "unrelated.pem"
        unrelated_key.write_text("existing unrelated key", encoding="utf-8")
        result = self.run_script("cleanup.sh", KEY_NAME="unrelated-key", PEM_FILE=str(unrelated_key))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("delete-vpc", self.actions())
        self.assertNotIn("delete-key-pair", self.actions())
        self.assertTrue(unrelated_key.exists())

    def test_existing_local_key_is_preserved_before_any_aws_calls(self):
        original = b"existing private key owned by an earlier run\n"
        self.pem.write_bytes(original)
        result = self.run_script("build.sh")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.pem.read_bytes(), original)
        self.assertFalse(self.state.exists())
        self.assertEqual(self.actions(), [])

    def test_missing_expected_account_refuses_before_aws_access(self):
        result = self.run_script("build.sh", EXPECTED_ACCOUNT_ID="")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.path / "aws-calls.log").exists())
        self.assertFalse(self.state.exists())

    def test_different_account_refuses_before_resource_creation(self):
        result = self.run_script("build.sh", MOCK_ACCOUNT_ID="222222222222")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.actions(), [])
        self.assertFalse(self.state.exists())

    def test_explicit_region_is_persisted_and_used_for_cleanup(self):
        result = self.run_script("build.sh", REGION="us-west-2", AZ="us-west-2b")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('REGION="us-west-2"', self.state.read_text(encoding="utf-8"))
        result = self.run_script("cleanup.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for line in (self.path / "aws-calls.log").read_text().splitlines():
            self.assertIn("--region us-west-2", line)

    def test_created_key_is_recorded_and_removed_by_cleanup(self):
        result = self.run_script("build.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('KEY_NAME="handson-key"', self.state.read_text(encoding="utf-8"))
        self.assertTrue(self.pem.exists())
        result = self.run_script("cleanup.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("delete-key-pair", self.actions())
        self.assertFalse(self.pem.exists())
        self.assertFalse(self.state.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
