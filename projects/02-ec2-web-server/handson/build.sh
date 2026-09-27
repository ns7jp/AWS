#!/usr/bin/env bash
# =============================================================================
# build.sh
# ../README.md の「ハンズオン手順」(フェーズ1〜4)を AWS CLI v2 で自動構築します。
#   VPC → サブネット → IGW → ルートテーブル → セキュリティグループ
#   → キーペア → EC2(user-data.sh で httpd を導入) → Elastic IP
# 作成したリソースIDは .handson-state.env に保存し、cleanup.sh が読み込んで削除します。
# =============================================================================
set -euo pipefail
umask 077

# -----------------------------------------------------------------------------
# 変数(必要に応じて編集してください)
# -----------------------------------------------------------------------------
REGION="${REGION:-ap-northeast-1}"       # 明示した実行リージョン。既定は東京
VPC_CIDR="10.0.0.0/16"                  # VPC のアドレス範囲
SUBNET_CIDR="10.0.1.0/24"               # パブリックサブネットのアドレス範囲
AZ="${AZ:-${REGION}a}"                  # 対象アカウントで使えるAZを指定
KEY_NAME="handson-key"                  # SSH 用キーペア名(.pem がこの名前で保存されます)
MY_IP="${MY_IP:-}"                      # 自分のグローバルIP(例: 203.0.113.10)。空なら自動取得
INSTANCE_TYPE="t3.micro"                # 無料利用条件はアカウントごとに確認
NAME_PREFIX="handson"                   # 各リソースの Name タグの接頭辞

# -----------------------------------------------------------------------------
# 事前準備
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/.handson-state.env"
USER_DATA_FILE="${SCRIPT_DIR}/user-data.sh"
PEM_FILE="${SCRIPT_DIR}/${KEY_NAME}.pem"

if [[ -f "${STATE_FILE}" ]]; then
  echo "エラー: ${STATE_FILE} が既に存在します。前回のリソースが残っている可能性があります。" >&2
  echo "       先に ./cleanup.sh を実行してください。" >&2
  exit 1
fi

if [[ -e "${PEM_FILE}" || -L "${PEM_FILE}" ]]; then
  echo "エラー: 既存の秘密鍵ファイルがあります。上書きせず停止します: ${PEM_FILE}" >&2
  exit 1
fi

# Read identity before creating resources. Never infer the intended account
# from whichever profile happens to be active.
if [[ ! "${EXPECTED_ACCOUNT_ID:-}" =~ ^[0-9]{12}$ ]]; then
  echo "エラー: 実行対象の12桁のAWSアカウントIDを EXPECTED_ACCOUNT_ID に指定してください。" >&2
  exit 1
fi
if ! command -v aws >/dev/null 2>&1; then
  echo "エラー: AWS CLI v2 が必要です。" >&2
  exit 1
fi
if [[ "$(aws --version 2>&1)" != aws-cli/2.* ]]; then
  echo "エラー: AWS CLI v2 を使用してください。" >&2
  exit 1
fi
ACCOUNT_ID="$(aws sts get-caller-identity --region "${REGION}" --query Account --output text)"
if [[ "${ACCOUNT_ID}" != "${EXPECTED_ACCOUNT_ID}" ]]; then
  echo "エラー: 認証先が指定したAWSアカウントと一致しません。リソースは作成していません。" >&2
  exit 1
fi

# MY_IP が未指定なら checkip.amazonaws.com から自動取得します
if [[ -z "${MY_IP}" ]]; then
  MY_IP="$(curl -s https://checkip.amazonaws.com)"
  echo "MY_IP を自動取得しました: ${MY_IP}"
fi

# 状態ファイルへ追記するヘルパー関数
save_state() {
  echo "$1=\"$2\"" >> "${STATE_FILE}"
}

echo "REGION=\"${REGION}\"" > "${STATE_FILE}"
save_state ACCOUNT_ID "${ACCOUNT_ID}"

echo "=== 構築を開始します (リージョン: ${REGION}) ==="

# -----------------------------------------------------------------------------
# フェーズ1-1: VPC を作成
# -----------------------------------------------------------------------------
echo "[1/9] VPC を作成中..."
VPC_ID="$(aws ec2 create-vpc \
  --region "${REGION}" \
  --cidr-block "${VPC_CIDR}" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${NAME_PREFIX}-web-vpc}]" \
  --query 'Vpc.VpcId' --output text)"
save_state VPC_ID "${VPC_ID}"
echo "  VPC_ID=${VPC_ID}"

# パブリックDNSホスト名を有効化(EC2 に ec2-xx-xx.compute.amazonaws.com の名前が付くようになります)
aws ec2 modify-vpc-attribute --region "${REGION}" --vpc-id "${VPC_ID}" --enable-dns-hostnames "{\"Value\":true}"

# -----------------------------------------------------------------------------
# フェーズ1-2: パブリックサブネットを作成
# -----------------------------------------------------------------------------
echo "[2/9] パブリックサブネットを作成中..."
SUBNET_ID="$(aws ec2 create-subnet \
  --region "${REGION}" \
  --vpc-id "${VPC_ID}" \
  --cidr-block "${SUBNET_CIDR}" \
  --availability-zone "${AZ}" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${NAME_PREFIX}-public-subnet-1a}]" \
  --query 'Subnet.SubnetId' --output text)"
save_state SUBNET_ID "${SUBNET_ID}"
echo "  SUBNET_ID=${SUBNET_ID}"

# 「パブリックIPの自動割り当て」を有効化
aws ec2 modify-subnet-attribute --region "${REGION}" --subnet-id "${SUBNET_ID}" --map-public-ip-on-launch

# -----------------------------------------------------------------------------
# フェーズ2-1: インターネットゲートウェイを作成して VPC にアタッチ
# -----------------------------------------------------------------------------
echo "[3/9] インターネットゲートウェイを作成・アタッチ中..."
IGW_ID="$(aws ec2 create-internet-gateway \
  --region "${REGION}" \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${NAME_PREFIX}-igw}]" \
  --query 'InternetGateway.InternetGatewayId' --output text)"
save_state IGW_ID "${IGW_ID}"
aws ec2 attach-internet-gateway --region "${REGION}" --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}"
echo "  IGW_ID=${IGW_ID}"

# -----------------------------------------------------------------------------
# フェーズ2-2: ルートテーブルを作成し 0.0.0.0/0 → IGW の経路を追加、サブネットに関連付け
# -----------------------------------------------------------------------------
echo "[4/9] ルートテーブルを作成中..."
RTB_ID="$(aws ec2 create-route-table \
  --region "${REGION}" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${NAME_PREFIX}-public-rtb}]" \
  --query 'RouteTable.RouteTableId' --output text)"
save_state RTB_ID "${RTB_ID}"

aws ec2 create-route --region "${REGION}" --route-table-id "${RTB_ID}" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "${IGW_ID}" > /dev/null

RTB_ASSOC_ID="$(aws ec2 associate-route-table \
  --region "${REGION}" \
  --route-table-id "${RTB_ID}" \
  --subnet-id "${SUBNET_ID}" \
  --query 'AssociationId' --output text)"
save_state RTB_ASSOC_ID "${RTB_ASSOC_ID}"
echo "  RTB_ID=${RTB_ID}"

# -----------------------------------------------------------------------------
# フェーズ3: セキュリティグループを作成(22 は自分のIPのみ、80/443 は全公開)
# -----------------------------------------------------------------------------
echo "[5/9] セキュリティグループを作成中..."
SG_ID="$(aws ec2 create-security-group \
  --region "${REGION}" \
  --group-name "${NAME_PREFIX}-web-sg" \
  --description "handson web server SG: SSH from my IP, HTTP/HTTPS from anywhere" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${NAME_PREFIX}-web-sg}]" \
  --query 'GroupId' --output text)"
save_state SG_ID "${SG_ID}"

aws ec2 authorize-security-group-ingress --region "${REGION}" --group-id "${SG_ID}" \
  --protocol tcp --port 22 --cidr "${MY_IP}/32" > /dev/null
aws ec2 authorize-security-group-ingress --region "${REGION}" --group-id "${SG_ID}" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0 > /dev/null
aws ec2 authorize-security-group-ingress --region "${REGION}" --group-id "${SG_ID}" \
  --protocol tcp --port 443 --cidr 0.0.0.0/0 > /dev/null
echo "  SG_ID=${SG_ID}"

# -----------------------------------------------------------------------------
# フェーズ4-1: キーペアを作成(秘密鍵はこのタイミングでしか取得できません)
# -----------------------------------------------------------------------------
echo "[6/9] キーペアを作成中..."
KEY_MATERIAL="$(aws ec2 create-key-pair \
  --region "${REGION}" \
  --key-name "${KEY_NAME}" \
  --key-type rsa \
  --key-format pem \
  --query 'KeyMaterial' --output text)"
# A duplicate-name failure above must never enroll a pre-existing AWS key
# for deletion. Record ownership only after CreateKeyPair succeeds.
save_state KEY_NAME "${KEY_NAME}"
# noclobber also protects a local file created after the initial check.
(set -o noclobber; printf '%s\n' "${KEY_MATERIAL}" > "${PEM_FILE}")
unset KEY_MATERIAL
save_state PEM_FILE "${PEM_FILE}"
chmod 400 "${PEM_FILE}"
echo "  秘密鍵を保存しました: ${PEM_FILE}"

# -----------------------------------------------------------------------------
# フェーズ4-2: 最新の Amazon Linux 2023 AMI ID を SSM パラメータストアから取得
# -----------------------------------------------------------------------------
echo "[7/9] 最新の Amazon Linux 2023 AMI を取得中..."
AMI_ID="$(aws ssm get-parameters \
  --region "${REGION}" \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)"
echo "  AMI_ID=${AMI_ID}"

# -----------------------------------------------------------------------------
# フェーズ4-3: EC2 インスタンスを起動(user-data.sh で httpd を自動セットアップ)
# -----------------------------------------------------------------------------
echo "[8/9] EC2 インスタンスを起動中..."
INSTANCE_ID="$(aws ec2 run-instances \
  --region "${REGION}" \
  --image-id "${AMI_ID}" \
  --instance-type "${INSTANCE_TYPE}" \
  --key-name "${KEY_NAME}" \
  --subnet-id "${SUBNET_ID}" \
  --security-group-ids "${SG_ID}" \
  --associate-public-ip-address \
  --user-data "file://${USER_DATA_FILE}" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME_PREFIX}-web-server}]" \
  --query 'Instances[0].InstanceId' --output text)"
save_state INSTANCE_ID "${INSTANCE_ID}"
echo "  INSTANCE_ID=${INSTANCE_ID}"
echo "  インスタンスが running になるまで待機します..."
aws ec2 wait instance-running --region "${REGION}" --instance-ids "${INSTANCE_ID}"

# -----------------------------------------------------------------------------
# フェーズ4-4: Elastic IP を割り当ててインスタンスに関連付け
# -----------------------------------------------------------------------------
echo "[9/9] Elastic IP を割り当て中..."
ALLOC_ID="$(aws ec2 allocate-address \
  --region "${REGION}" \
  --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${NAME_PREFIX}-web-eip}]" \
  --query 'AllocationId' --output text)"
save_state ALLOC_ID "${ALLOC_ID}"

aws ec2 associate-address --region "${REGION}" \
  --instance-id "${INSTANCE_ID}" --allocation-id "${ALLOC_ID}" > /dev/null

EIP="$(aws ec2 describe-addresses --region "${REGION}" \
  --allocation-ids "${ALLOC_ID}" --query 'Addresses[0].PublicIp' --output text)"
save_state EIP "${EIP}"

# -----------------------------------------------------------------------------
# 完了
# -----------------------------------------------------------------------------
cat <<EOF

=== 構築が完了しました ===
  Web ページ : http://${EIP}
    ※ user-data による httpd のセットアップに 1〜2 分かかります。表示されない場合は少し待ってから再読み込みしてください。
  SSH 接続   : ssh -i "${PEM_FILE}" ec2-user@${EIP}

  作成したリソースIDは ${STATE_FILE} に保存しました。
  使い終わったら必ず ./cleanup.sh を実行して削除してください(Elastic IP の放置は課金対象です)。
EOF
