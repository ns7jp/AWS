#!/usr/bin/env bash
# Delete only recorded resources. Preserve state and local keys on failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/.handson-state.env"
if [[ ! -f "${STATE_FILE}" ]]; then
  echo "エラー: ${STATE_FILE} がありません。削除済みとは判断できません。" >&2
  exit 1
fi

# Trusted local state from build.sh; never source a file from another person.
# A missing field in a partial build must not inherit an unrelated target
# from the caller's environment.
unset REGION ACCOUNT_ID ALLOC_ID INSTANCE_ID SG_ID RTB_ASSOC_ID RTB_ID IGW_ID SUBNET_ID VPC_ID KEY_NAME PEM_FILE
# shellcheck disable=SC1090
source "${STATE_FILE}"
REGION="${REGION:-ap-northeast-1}"
# The local state is meaningful only in the account that created it.
# Legacy states without an account must be checked before any deletion.
if [[ ! "${ACCOUNT_ID:-}" =~ ^[0-9]{12}$ ]]; then
  echo "エラー: 状態ファイルに作成元のACCOUNT_IDがありません。対象アカウントと各リソースの所有関係を確認してから補ってください。削除は実行していません。" >&2
  exit 1
fi
CURRENT_ACCOUNT_ID="$(aws sts get-caller-identity --region "${REGION}" --query Account --output text)"
if [[ "${CURRENT_ACCOUNT_ID}" != "${ACCOUNT_ID}" ]]; then
  echo "エラー: 認証先が作成元のAWSアカウントと一致しません。状態ファイルと秘密鍵を保持し、削除は実行していません。" >&2
  exit 1
fi
FAILURES=()
AWS_OUTPUT=""
AWS_ABSENT=0

# Accept only operation-specific EC2 already-absent error codes.
# https://docs.aws.amazon.com/ec2/latest/devguide/errors-overview.html
aws_step() {
  local label="$1" absent_codes="$2" status code
  local error_pattern='An error occurred \(([^()]*)\) when calling '
  shift 2
  AWS_OUTPUT=""
  AWS_ABSENT=0
  if AWS_OUTPUT="$(aws ec2 "$@" --region "${REGION}" 2>&1)"; then
    return 0
  else
    status=$?
  fi
  if [[ "${AWS_OUTPUT}" =~ ${error_pattern} ]]; then
    code="${BASH_REMATCH[1]}"
    if [[ " ${absent_codes} " == *" ${code} "* && -n "${code}" ]]; then
      echo "  既に削除・解除済み: ${label} (${code})"
      AWS_ABSENT=1
      return 0
    fi
  fi
  FAILURES+=("${label} (exit ${status})")
  printf '  失敗: %s\n%s\n' "${label}" "${AWS_OUTPUT}" >&2
  return 1
}

echo "=== 記録済みリソースの削除を開始します (リージョン: ${REGION}) ==="

# 1. A failed lookup is not proof that the address is absent/unassociated.
if [[ -n "${ALLOC_ID:-}" ]]; then
  if aws_step "Elastic IP照会 ${ALLOC_ID}" "InvalidAllocationID.NotFound" \
      describe-addresses --allocation-ids "${ALLOC_ID}" \
      --query 'Addresses[0].AssociationId' --output text; then
    if [[ "${AWS_ABSENT}" -eq 0 ]]; then
      ASSOC_ID="${AWS_OUTPUT}"
      if [[ -n "${ASSOC_ID}" && "${ASSOC_ID}" != "None" ]]; then
        aws_step "Elastic IP関連付け解除 ${ASSOC_ID}" "InvalidAssociationID.NotFound" \
          disassociate-address --association-id "${ASSOC_ID}" || :
      fi
      aws_step "Elastic IP解放 ${ALLOC_ID}" "InvalidAllocationID.NotFound" \
        release-address --allocation-id "${ALLOC_ID}" || :
    fi
  fi
fi

# 2. A successful terminate request is not proof of termination: wait for it.
if [[ -n "${INSTANCE_ID:-}" ]]; then
  if aws_step "EC2終了 ${INSTANCE_ID}" "InvalidInstanceID.NotFound" \
      terminate-instances --instance-ids "${INSTANCE_ID}"; then
    if [[ "${AWS_ABSENT}" -eq 0 ]]; then
      aws_step "EC2終了待機 ${INSTANCE_ID}" "InvalidInstanceID.NotFound" \
        wait instance-terminated --instance-ids "${INSTANCE_ID}" || :
    fi
  fi
fi

# Keep trying other recorded resources; aws_step records every failure.
if [[ -n "${SG_ID:-}" ]]; then
  aws_step "SG削除 ${SG_ID}" "InvalidGroup.NotFound" \
    delete-security-group --group-id "${SG_ID}" || :
fi
if [[ -n "${RTB_ASSOC_ID:-}" ]]; then
  aws_step "ルート関連付け解除 ${RTB_ASSOC_ID}" "InvalidAssociationID.NotFound" \
    disassociate-route-table --association-id "${RTB_ASSOC_ID}" || :
fi
if [[ -n "${RTB_ID:-}" ]]; then
  aws_step "ルートテーブル削除 ${RTB_ID}" "InvalidRouteTableID.NotFound" \
    delete-route-table --route-table-id "${RTB_ID}" || :
fi
if [[ -n "${IGW_ID:-}" ]]; then
  if [[ -n "${VPC_ID:-}" ]]; then
    aws_step "IGW解除 ${IGW_ID}" "Gateway.NotAttached InvalidInternetGatewayID.NotFound InvalidVpcID.NotFound" \
      detach-internet-gateway --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}" || :
  fi
  aws_step "IGW削除 ${IGW_ID}" "InvalidInternetGatewayID.NotFound" \
    delete-internet-gateway --internet-gateway-id "${IGW_ID}" || :
fi
if [[ -n "${SUBNET_ID:-}" ]]; then
  aws_step "サブネット削除 ${SUBNET_ID}" "InvalidSubnetID.NotFound" \
    delete-subnet --subnet-id "${SUBNET_ID}" || :
fi
if [[ -n "${VPC_ID:-}" ]]; then
  aws_step "VPC削除 ${VPC_ID}" "InvalidVpcID.NotFound" \
    delete-vpc --vpc-id "${VPC_ID}" || :
fi
if [[ -n "${KEY_NAME:-}" ]]; then
  aws_step "キーペア削除 ${KEY_NAME}" "InvalidKeyPair.NotFound" \
    delete-key-pair --key-name "${KEY_NAME}" || :
fi

if [[ "${#FAILURES[@]}" -gt 0 ]]; then
  printf '\n削除未完了。失敗・未確認の操作:\n' >&2
  printf '  - %s\n' "${FAILURES[@]}" >&2
  echo "状態ファイルとローカル秘密鍵を保持しました。原因を解消し、このスクリプトを再実行してください。" >&2
  exit 1
fi

# Remove local files only when every recorded AWS operation is confirmed.
if [[ -n "${PEM_FILE:-}" && -f "${PEM_FILE}" ]]; then
  if ! rm -f -- "${PEM_FILE}"; then
    echo "秘密鍵ファイルを削除できません。状態ファイルを保持しました。" >&2
    exit 1
  fi
fi
if ! rm -f -- "${STATE_FILE}"; then
  echo "状態ファイルを削除できません。手元のファイルを確認してください。" >&2
  exit 1
fi

cat <<'EOF'

=== 記録済みリソースの削除API処理を確認しました ===
各サービスで対象のEC2・EBS・Elastic IP・VPC関連リソースの残存を確認してください。
この表示はアカウント全体の残存リソースや後日の請求額を確認した証拠ではありません。
EOF
