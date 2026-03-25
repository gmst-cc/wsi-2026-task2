#!/bin/bash
# WorldPay EFS 과제 채점 스크립트
# CloudShell에서 실행: bash grade_efs.sh

REGION="ap-northeast-2"
SCORE=0

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✓ PASS${NC} (+${2}점)"; SCORE=$((SCORE + $2)); }
fail() { echo -e "  ${RED}✗ FAIL${NC} (0점)"; }
section() { echo -e "\n${CYAN}${BOLD}== $1 ==${NC}"; }

echo -e "${BOLD}=============================="
echo " WorldPay EFS 과제 채점"
echo -e "==============================${NC}"


# ── VPC ───────────────────────────────────────────────────────────
section "VPC 확인"
CMD='aws ec2 describe-vpcs --filters "Name=tag:Name,Values=wsi-efs-vpc" "Name=cidr,Values=10.0.0.0/16" --query "Vpcs[0].VpcId" --output text --region ap-northeast-2'
echo "  명령어: $CMD"
VPC_ID=$(eval $CMD 2>/dev/null)
echo "  예상 출력 값: vpc-xxxxxxxxxx"
echo "  실제 출력 값: $VPC_ID"
if [[ "$VPC_ID" != "None" && -n "$VPC_ID" ]]; then
    pass "wsi-efs-vpc 존재" 0
    # 서브넷
    section "서브넷 확인"
    SUB_A_CMD='aws ec2 describe-subnets --filters "Name=tag:Name,Values=wsi-efs-sub-a" "Name=availabilityZone,Values=ap-northeast-2a" --query "Subnets[0].SubnetId" --output text --region ap-northeast-2'
    SUB_C_CMD='aws ec2 describe-subnets --filters "Name=tag:Name,Values=wsi-efs-sub-c" "Name=availabilityZone,Values=ap-northeast-2c" --query "Subnets[0].SubnetId" --output text --region ap-northeast-2'
    echo "  명령어: $SUB_A_CMD"
    SUB_A=$(eval $SUB_A_CMD 2>/dev/null)
    SUB_C=$(eval $SUB_C_CMD 2>/dev/null)
    echo "  예상 출력 값: subnet-xxxxxxxxxx (2a), subnet-xxxxxxxxxx (2c)"
    echo "  실제 출력 값: $SUB_A (2a), $SUB_C (2c)"
    if [[ "$SUB_A" != "None" && -n "$SUB_A" && "$SUB_C" != "None" && -n "$SUB_C" ]]; then
        pass "서브넷 2개 구성" 0
    else
        fail "서브넷 누락"
    fi
else
    fail "wsi-efs-vpc 없음"
fi


# ── Security Group ────────────────────────────────────────────────
section "Security Group 확인 (sg-wsi-efs → TCP 2049 → sg-wsi-ec2만 허용)"
SG_EFS_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=wsi-efs" \
    --query "SecurityGroups[0].GroupId" --output text --region $REGION 2>/dev/null)
SG_EC2_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=wsi-ec2" \
    --query "SecurityGroups[0].GroupId" --output text --region $REGION 2>/dev/null)

CMD="aws ec2 describe-security-groups --group-ids $SG_EFS_ID --query \"SecurityGroups[0].IpPermissions\" --output json --region ap-northeast-2"
echo "  명령어: $CMD"
INBOUND=$(eval $CMD 2>/dev/null)
echo "  예상 출력 값: Port 2049, UserIdGroupPairs[0].GroupId = $SG_EC2_ID"
echo "  실제 출력 값:"
echo "$INBOUND" | python3 -c "
import json,sys
rules = json.load(sys.stdin)
for r in rules:
    port = r.get('FromPort','')
    groups = [g['GroupId'] for g in r.get('UserIdGroupPairs',[])]
    ranges = [ip['CidrIp'] for ip in r.get('IpRanges',[])]
    print(f'    Port {port} | SG: {groups} | CIDR: {ranges}')
" 2>/dev/null

INBOUND_OK=$(echo "$INBOUND" | python3 -c "
import json,sys
rules = json.load(sys.stdin)
for r in rules:
    if r.get('FromPort') == 2049:
        groups = [g['GroupId'] for g in r.get('UserIdGroupPairs',[])]
        cidrs = [ip['CidrIp'] for ip in r.get('IpRanges',[])]
        if '${SG_EC2_ID}' in groups and not cidrs:
            print('OK')
" 2>/dev/null)

if [[ "$INBOUND_OK" == "OK" ]]; then
    pass "sg-efs: 2049 → sg-ec2만 허용" 2
else
    fail "sg-efs 규칙 불일치 (0.0.0.0/0 개방 또는 sg-ec2 미지정)"
fi


# ── EC2 ──────────────────────────────────────────────────────────
section "EC2 인스턴스 확인"
for SERVER in "wsi-app-server-a:ap-northeast-2a" "wsi-app-server-c:ap-northeast-2c"; do
    NAME="${SERVER%%:*}"
    AZ="${SERVER##*:}"
    CMD="aws ec2 describe-instances --filters \"Name=tag:Name,Values=$NAME\" \"Name=instance-state-name,Values=running\" --query \"Reservations[0].Instances[0].InstanceId\" --output text --region ap-northeast-2"
    echo "  명령어: $CMD"
    INST=$(eval $CMD 2>/dev/null)
    INST_AZ=$(aws ec2 describe-instances --instance-ids $INST \
        --query "Reservations[0].Instances[0].Placement.AvailabilityZone" \
        --output text --region $REGION 2>/dev/null)
    echo "  예상 출력 값: i-xxxxxxxxxx ($AZ)"
    echo "  실제 출력 값: $INST ($INST_AZ)"
    if [[ "$INST" != "None" && -n "$INST" && "$INST_AZ" == "$AZ" ]]; then
        pass "$NAME 존재 ($AZ)" 0
    else
        fail "$NAME 없음 또는 AZ 불일치"
    fi
done


# ── EFS ──────────────────────────────────────────────────────────
section "EFS 파일 시스템 확인"
CMD='aws efs describe-file-systems --query "FileSystems[?Name==\`wsi-shared-efs\`].[FileSystemId,Encrypted,KmsKeyId]" --output text --region ap-northeast-2'
echo "  명령어: $CMD"
EFS_INFO=$(eval $CMD 2>/dev/null)
EFS_ID=$(echo "$EFS_INFO" | awk '{print $1}')
EFS_ENC=$(echo "$EFS_INFO" | awk '{print $2}')
EFS_KMS=$(echo "$EFS_INFO" | awk '{print $3}')
echo "  예상 출력 값: fs-xxxxxxxxxx  True  arn:aws:kms:...:alias/wsi-efs-key"
echo "  실제 출력 값: $EFS_ID  $EFS_ENC  $EFS_KMS"

KMS_ALIAS=$(aws kms list-aliases --query "Aliases[?AliasName==\`alias/wsi-efs-key\`].TargetKeyId" \
    --output text --region $REGION 2>/dev/null)
if [[ -n "$EFS_ID" && "$EFS_ENC" == "True" && "$EFS_KMS" == *"$KMS_ALIAS"* ]]; then
    pass "EFS 생성 + KMS(alias/wsi-efs-key) 암호화" 3
else
    if [[ -n "$EFS_ID" && "$EFS_ENC" == "True" ]]; then
        echo -e "  ${RED}✗ FAIL${NC} EFS는 있으나 KMS 키 불일치 (+1점)"
        SCORE=$((SCORE + 1))
    else
        fail "EFS 없음 또는 암호화 미적용"
    fi
fi


# ── EFS Mount Target ─────────────────────────────────────────────
section "EFS 마운트 타겟 확인 (AZ 2개)"
CMD="aws efs describe-mount-targets --file-system-id $EFS_ID --query \"MountTargets[].AvailabilityZoneName\" --output text --region ap-northeast-2"
echo "  명령어: $CMD"
MT_AZS=$(eval $CMD 2>/dev/null)
echo "  예상 출력 값: ap-northeast-2a  ap-northeast-2c"
echo "  실제 출력 값: $MT_AZS"
if echo "$MT_AZS" | grep -q "ap-northeast-2a" && echo "$MT_AZS" | grep -q "ap-northeast-2c"; then
    pass "마운트 타겟 2개 (2a, 2c)" 2
else
    fail "마운트 타겟 AZ 누락"
fi


# ── EFS Lifecycle ────────────────────────────────────────────────
section "EFS 수명 주기 정책 확인 (30일 IA)"
CMD="aws efs describe-lifecycle-configuration --file-system-id $EFS_ID --query \"LifecyclePolicies\" --output json --region ap-northeast-2"
echo "  명령어: $CMD"
LC=$(eval $CMD 2>/dev/null)
echo "  예상 출력 값: [{\"TransitionToIA\": \"AFTER_30_DAYS\"}]"
echo "  실제 출력 값: $LC"
if echo "$LC" | grep -q "AFTER_30_DAYS"; then
    pass "수명 주기 정책 30일 IA" 1
else
    fail "수명 주기 정책 없음 또는 30일 아님"
fi


# ── EFS Access Point ─────────────────────────────────────────────
section "EFS Access Point 확인"
CMD="aws efs describe-access-points --file-system-id $EFS_ID --query \"AccessPoints[?Tags[?Key=='Name' && Value=='wsi-efs-ap']].[AccessPointId,RootDirectory.Path,PosixUser.Uid,PosixUser.Gid]\" --output text --region ap-northeast-2"
echo "  명령어: $CMD"
AP_INFO=$(eval $CMD 2>/dev/null)
AP_ID=$(echo "$AP_INFO" | awk '{print $1}')
AP_PATH=$(echo "$AP_INFO" | awk '{print $2}')
AP_UID=$(echo "$AP_INFO" | awk '{print $3}')
AP_GID=$(echo "$AP_INFO" | awk '{print $4}')
echo "  예상 출력 값: ap-xxxxxxxxxx  /shared  1000  1000"
echo "  실제 출력 값: $AP_ID  $AP_PATH  $AP_UID  $AP_GID"
if [[ "$AP_PATH" == "/shared" && "$AP_UID" == "1000" && "$AP_GID" == "1000" ]]; then
    pass "Access Point (경로 /shared, UID/GID 1000)" 3
else
    fail "Access Point 설정 불일치"
fi


# ── EC2 마운트 확인 (SSM) ─────────────────────────────────────────
section "EC2 마운트 확인 (/mnt/shared, TLS, fstab)"
for SERVER in "wsi-app-server-a" "wsi-app-server-c"; do
    INST_ID=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$SERVER" "Name=instance-state-name,Values=running" \
        --query "Reservations[0].Instances[0].InstanceId" --output text --region $REGION 2>/dev/null)

    echo "  [$SERVER] SSM mount 확인"

    CMD_ID=$(aws ssm send-command \
        --instance-ids "$INST_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["mount | grep /mnt/shared"]' \
        --query "Command.CommandId" --output text --region $REGION 2>/dev/null)

    sleep 3

    MOUNT_OUT=$(aws ssm get-command-invocation \
        --command-id "$CMD_ID" --instance-id "$INST_ID" \
        --query "StandardOutputContent" --output text --region $REGION 2>/dev/null)

    echo "  예상 출력 값: ... /mnt/shared ..."
    echo "  실제 출력 값: $MOUNT_OUT"

    FSTAB_ID=$(aws ssm send-command \
        --instance-ids "$INST_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["cat /etc/fstab"]' \
        --query "Command.CommandId" --output text --region $REGION 2>/dev/null)

    sleep 3

    FSTAB_OUT=$(aws ssm get-command-invocation \
        --command-id "$FSTAB_ID" --instance-id "$INST_ID" \
        --query "StandardOutputContent" --output text --region $REGION 2>/dev/null)

    echo "  [fstab] 실제 출력 값:"
    echo "$FSTAB_OUT"

    # mount 체크
    MOUNT_OK=false
    echo "$MOUNT_OUT" | grep -q "/mnt/shared" && MOUNT_OK=true

    # TLS + accesspoint + _netdev 체크 (fstab 기준)
    TLS_OK=false
    echo "$FSTAB_OUT" | awk '/\/mnt\/shared/ && /accesspoint/ && /tls/ && /_netdev/' >/dev/null && TLS_OK=true

    $MOUNT_OK && pass "$SERVER 마운트 확인" 1 || fail "$SERVER 마운트 실패"
    $TLS_OK && pass "$SERVER TLS 설정 (fstab)" 1 || fail "$SERVER TLS 설정 없음"
done


# ── 파일 공유 검증 ────────────────────────────────────────────────
section "서버 간 파일 공유 확인"
INST_A=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=wsi-app-server-a" "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text --region $REGION 2>/dev/null)
INST_C=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=wsi-app-server-c" "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text --region $REGION 2>/dev/null)

TESTFILE="grading_test_$(date +%s).txt"
echo "  [server-a] $TESTFILE 파일 생성"
WRITE_ID=$(aws ssm send-command \
    --instance-ids "$INST_A" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"echo 'grading_ok' > /mnt/shared/$TESTFILE\"]" \
    --query "Command.CommandId" --output text --region $REGION 2>/dev/null)
sleep 5

echo "  [server-c] $TESTFILE 파일 조회"
READ_ID=$(aws ssm send-command \
    --instance-ids "$INST_C" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"cat /mnt/shared/$TESTFILE\"]" \
    --query "Command.CommandId" --output text --region $REGION 2>/dev/null)
sleep 3
READ_OUT=$(aws ssm get-command-invocation \
    --command-id "$READ_ID" --instance-id "$INST_C" \
    --query "StandardOutputContent" --output text --region $REGION 2>/dev/null)

echo "  예상 출력 값: grading_ok"
echo "  실제 출력 값: $READ_OUT"
if echo "$READ_OUT" | grep -q "grading_ok"; then
    pass "서버 간 파일 공유 확인" 5
else
    fail "파일 공유 실패"
fi

# 테스트 파일 정리
aws ssm send-command \
    --instance-ids "$INST_A" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"rm -f /mnt/shared/$TESTFILE\"]" \
    --region $REGION > /dev/null 2>&1


# ── 결과 ─────────────────────────────────────────────────────────
echo -e "\n${BOLD}=============================="
echo -e " 최종 점수: ${SCORE} / 20 점"
echo -e "==============================${NC}"
