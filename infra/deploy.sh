#!/usr/bin/env bash
# code2 operations. Infrastructure goes through CloudFormation change sets (plan, look, then apply).
set -euo pipefail

usage() {
  cat <<'EOF'
infra/deploy.sh <command>

  stack plan          change set for the code2 stack (infra/code2.yaml); changes nothing
  stack apply         execute the change set made by the last plan
  status              URL, instance state, services, /home usage
  logs [-f] [since]   setup log from CloudWatch Logs (default since 1h)
  reconfigure         run the current user data on the instance again (no restart)
  ssh [args]          SSH as ec2-user through the stack's EICE (one-off key via EC2 Instance Connect)
  ssh-config          ~/.ssh/config block for ssh / VS Code Remote-SSH (keys must be pushed per use)
  shell               Session Manager shell on the instance
  stop | start        stop or start the instance (the NAT gateway keeps billing while stopped)
  destroy             delete the stack, then list what it leaves behind (user pool, snapshots)

Settings (environment). Unset ones keep their current value on update; create-time ones are fixed after create.
  CODE2_ADMIN_EMAIL            required on create: where Cognito sends the temporary password
  CODE2_ADMIN_USER             sign-in name (default admin; a new name recreates the user)
  CODE2_STACK                  stack name, lowercase (default code2)
  CODE2_ACCOUNT                refuse to run with credentials for any other account
  AWS_REGION                   default: AWS_DEFAULT_REGION, the profile's region, then ap-northeast-2
  CODE2_INSTANCE_TYPE          default t4g.medium; Graviton or x86 (another architecture replaces the instance)
  CODE2_DATA_SIZE              /home GiB (default 50, grow only)
  CODE2_ROOT_SIZE              root GiB (default 30, a change replaces the instance)
  CODE2_CODE_SERVER_VERSION    code-server version (a change restarts the instance)
  CODE2_OAUTH2_PROXY_VERSION   oauth2-proxy version (a change restarts the instance)
  CODE2_SESSION_HOURS          sign-in lifetime (default 12)
  CODE2_AUTO_UPDATES           true|false daily security updates (default true)
  CODE2_IDLE_STOP_HOURS        stop after this many idle hours (default 0 = never)
  CODE2_BACKUP_COUNT           daily /home snapshots kept (default 7, 0 = off)
  CODE2_ALARM_EMAIL            CloudWatch alarm mails (default none)
  CODE2_PRICE_CLASS            PriceClass_100|200|All (default PriceClass_200)
  CODE2_UPDATE_AMI=1           move to the latest AL2023 AMI (replaces the instance; /home stays)
  CODE2_KEEP_ON_FAILURE=1      apply without rollback, to inspect a failed create
  create-time:
  CODE2_DOMAIN                 custom name, e.g. code.example.com (Route 53 public zone + us-east-1 ACM cert)
  CODE2_ZONE / CODE2_ZONE_ID   hosted zone name or id of CODE2_DOMAIN (default: found from the domain)
  CODE2_CERT_ARN               certificate (default: an issued us-east-1 certificate covering CODE2_DOMAIN)
  CODE2_AZ                     AZ (default: the first one offering the instance type)
  CODE2_VPC_ID, CODE2_SUBNET_ID  use an existing VPC and private subnet (with NAT egress) instead of a new VPC
  CODE2_RESTORE_SNAPSHOT       snap-... to create /home from (a snapshot of an earlier code2 /home)
EOF
  exit 2
}

die() { echo "$*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }

case "${1:-}" in ""|-h|--help|help) usage ;; esac
command -v jq >/dev/null || die "jq is required"
command -v aws >/dev/null || die "AWS CLI v2 is required"
aws --version 2>&1 | grep -q '^aws-cli/2' || die "AWS CLI v2 is required (found: $(aws --version 2>&1))"

region=${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}
export AWS_REGION=${region:-ap-northeast-2}
STACK=${CODE2_STACK:-code2}
TEMPLATE=$(cd "$(dirname "$0")" && pwd)/code2.yaml

caller=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo none)
[ "$caller" != none ] || die "no AWS credentials: sign in first (aws login, aws sso login, or AWS_PROFILE=...)"
if [ -n "${CODE2_ACCOUNT:-}" ] && [ "$caller" != "$CODE2_ACCOUNT" ]; then
  die "refusing to run: credentials are for account $caller, CODE2_ACCOUNT is $CODE2_ACCOUNT"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
is_set() { declare -p "$1" >/dev/null 2>&1; }

# ---------- stack state ----------
stack_status() { aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE; }
has_resource() { aws cloudformation describe-stack-resource --stack-name "$STACK" --logical-resource-id "$1" >/dev/null 2>&1; }
physical_id() { aws cloudformation describe-stack-resource --stack-name "$STACK" --logical-resource-id "$1" \
  --query StackResourceDetail.PhysicalResourceId --output text 2>/dev/null || true; }

# Stops on states a change set cannot start from, with what to do instead.
check_state() {
  local s; s=$(stack_status)
  case "$s" in
    NONE|REVIEW_IN_PROGRESS|*_COMPLETE) ;;
    *_IN_PROGRESS) die "$STACK is busy ($s); wait for it to finish" ;;
    UPDATE_ROLLBACK_FAILED) die "$STACK is $s: fix the cause shown in its events, then run
  aws cloudformation continue-update-rollback --stack-name $STACK" ;;
    CREATE_FAILED) die "$STACK failed to create (kept for inspection); run infra/deploy.sh destroy, then plan again" ;;
    *) die "$STACK is $s: see its events (aws cloudformation describe-stack-events --stack-name $STACK)" ;;
  esac
  if [ "$s" = ROLLBACK_COMPLETE ]; then
    die "$STACK failed to create and rolled back, so it cannot be updated. See why with
  aws cloudformation describe-stack-events --stack-name $STACK
then run infra/deploy.sh destroy and plan again"
  fi
}

# ---------- parameters ----------
PARAMS='[]'
param() { PARAMS=$(jq -c --arg k "$1" --arg v "$2" '. + [{ParameterKey: $k, ParameterValue: $v}]' <<<"$PARAMS"); }
keep() { PARAMS=$(jq -c --arg k "$1" '. + [{ParameterKey: $k, UsePreviousValue: true}]' <<<"$PARAMS"); }

# ParameterKey:ENV pairs that may change after create.
TUNABLES="InstanceType:CODE2_INSTANCE_TYPE DataVolumeSize:CODE2_DATA_SIZE RootVolumeSize:CODE2_ROOT_SIZE
  CodeServerVersion:CODE2_CODE_SERVER_VERSION OAuth2ProxyVersion:CODE2_OAUTH2_PROXY_VERSION
  SessionHours:CODE2_SESSION_HOURS AutoUpdates:CODE2_AUTO_UPDATES IdleStopHours:CODE2_IDLE_STOP_HOURS
  BackupRetainCount:CODE2_BACKUP_COUNT AlarmEmail:CODE2_ALARM_EMAIL PriceClass:CODE2_PRICE_CLASS
  AdminUsername:CODE2_ADMIN_USER AdminEmail:CODE2_ADMIN_EMAIL"
# Fixed after create (network, edge, the volume's source, the boot signal).
CREATE_ONLY="AvailabilityZone VpcCidr PublicSubnetCidr PrivateSubnetCidr ExistingVpcId ExistingSubnetId ExistingEiceId
  ExistingEiceSecurityGroupId DomainName HostedZoneId CertificateArn DataSnapshotId WaitForBoot"

arch_of() { aws ec2 describe-instance-types --instance-types "$1" --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures' \
  --output text 2>/dev/null | tr '\t' '\n' | grep -E '^(arm64|x86_64)$' | head -1 || true; }
latest_ami() { aws ssm get-parameter --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-$1" \
  --query Parameter.Value --output text; }

# The instance's :80 accepts CloudFront's origin-facing addresses only (VPC origin traffic comes from them).
prefix_list() {
  local id
  id=$(aws ec2 describe-managed-prefix-lists --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
    --query 'PrefixLists[0].PrefixListId' --output text)
  [[ "$id" == pl-* ]] || die "no CloudFront origin-facing prefix list in $AWS_REGION"
  echo "$id"
}

# Hosted zone: CODE2_ZONE_ID, else CODE2_ZONE, else the closest public zone that DOMAIN sits in.
find_zone() {
  local name id
  if [ -n "${CODE2_ZONE_ID:-}" ]; then echo "${CODE2_ZONE_ID#/hostedzone/}"; return; fi
  name=${CODE2_ZONE:-$1}
  while :; do
    id=$(aws route53 list-hosted-zones-by-name --dns-name "$name" --max-items 10 --output json \
      | jq -r --arg n "$name." '.HostedZones[] | select(.Name == $n and (.Config.PrivateZone | not)) | .Id' | head -1)
    if [ -n "$id" ]; then echo "${id#/hostedzone/}"; return; fi
    [ -z "${CODE2_ZONE:-}" ] && [[ "$name" == *.*.* ]] || break
    name=${name#*.}
  done
  die "no Route 53 public hosted zone for $1 (set CODE2_ZONE or CODE2_ZONE_ID)"
}

# Certificate: CODE2_CERT_ARN, else an issued us-east-1 certificate whose names (SANs included) cover DOMAIN.
find_cert() {
  local arn
  if [ -n "${CODE2_CERT_ARN:-}" ]; then echo "$CODE2_CERT_ARN"; return; fi
  arn=$(aws acm list-certificates --region us-east-1 --certificate-statuses ISSUED \
      --includes keyTypes=RSA_2048,RSA_3072,RSA_4096,EC_prime256v1,EC_secp384r1 --output json \
    | jq -r --arg d "$1" --arg w "*.${1#*.}" \
      '[.CertificateSummaryList[] | select(((.SubjectAlternativeNameSummaries // []) + [.DomainName]) | any(. == $d or . == $w))][0].CertificateArn // empty')
  [ -n "$arn" ] || die "no issued us-east-1 ACM certificate covers $1 (request one, or set CODE2_CERT_ARN)"
  echo "$arn"
}

preflight_create() {
  local type=$1 az=$2 n
  [[ "$STACK" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "CODE2_STACK must be lowercase letters, digits and hyphens"
  [ ${#STACK} -le 50 ] || die "CODE2_STACK is longer than 50 characters (it prefixes the Cognito domain)"
  [[ "$STACK" =~ aws|amazon|cognito ]] && die "CODE2_STACK cannot contain aws, amazon or cognito (Cognito domain rule)"
  aws ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters "Name=location,Values=$az" "Name=instance-type,Values=$type" --query 'InstanceTypeOfferings[0]' \
    --output text | grep -q "$type" || die "$type is not offered in $az (set CODE2_AZ or CODE2_INSTANCE_TYPE)"
  n=$(aws ec2 describe-instance-connect-endpoints --query 'length(InstanceConnectEndpoints)' --output text 2>/dev/null || echo 0)
  [ "$n" -lt 5 ] || warn "$n EC2 Instance Connect Endpoints in $AWS_REGION already (default quota 5)"
  if [ -z "${CODE2_VPC_ID:-}" ]; then
    n=$(aws ec2 describe-vpcs --query 'length(Vpcs)' --output text)
    [ "$n" -lt 5 ] || warn "$n VPCs in $AWS_REGION already (default quota 5)"
    n=$(aws ec2 describe-addresses --query 'length(Addresses)' --output text)
    [ "$n" -lt 5 ] || warn "$n Elastic IPs in $AWS_REGION already (default quota 5)"
  fi
}

params_create() {
  local type=${CODE2_INSTANCE_TYPE:-t4g.medium} arch ami az="${CODE2_AZ:-}" pair k v vpc eice zone cert pl
  [ -n "${CODE2_ADMIN_EMAIL:-}" ] || die "set CODE2_ADMIN_EMAIL (the temporary password goes there)"
  arch=$(arch_of "$type"); [ -n "$arch" ] || die "unknown instance type $type in $AWS_REGION"
  ami=$(latest_ami "$arch"); param ImageId "$ami"
  pl=$(prefix_list); param CloudFrontPrefixListId "$pl"

  if [ -n "${CODE2_VPC_ID:-}" ]; then
    vpc=$CODE2_VPC_ID
    [ -n "${CODE2_SUBNET_ID:-}" ] || die "CODE2_VPC_ID needs CODE2_SUBNET_ID (a private subnet with NAT egress)"
    read -r v az < <(aws ec2 describe-subnets --subnet-ids "$CODE2_SUBNET_ID" --query 'Subnets[0].[VpcId,AvailabilityZone]' --output text)
    [ "$v" = "$vpc" ] || die "$CODE2_SUBNET_ID is in $v, not $vpc"
    aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc" --query 'InternetGateways[0].InternetGatewayId' \
      --output text | grep -q '^igw-' || die "$vpc has no internet gateway (CloudFront VPC origins need one)"
    aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$CODE2_SUBNET_ID" \
      --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].NatGatewayId' --output text | grep -q '^nat-' \
      || warn "$CODE2_SUBNET_ID has no 0.0.0.0/0 route to a NAT gateway in its own route table; the instance needs internet egress"
    param ExistingVpcId "$vpc"; param ExistingSubnetId "$CODE2_SUBNET_ID"
    read -r eice v < <(aws ec2 describe-instance-connect-endpoints --filters "Name=vpc-id,Values=$vpc" \
      --query 'InstanceConnectEndpoints[0].[InstanceConnectEndpointId,SecurityGroupIds[0]]' --output text)
    if [[ "$eice" == eice-* ]]; then
      echo "using the VPC's EC2 Instance Connect Endpoint $eice ($v)"
      param ExistingEiceId "$eice"; param ExistingEiceSecurityGroupId "$v"
    fi
  elif [ -z "$az" ]; then
    az=$(aws ec2 describe-instance-type-offerings --location-type availability-zone \
      --filters "Name=instance-type,Values=$type" --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' '\n' | sort | head -1)
    [ -n "$az" ] || die "$type is not offered in any AZ of $AWS_REGION"
  fi
  preflight_create "$type" "$az"
  param AvailabilityZone "$az"

  if [ -n "${CODE2_DOMAIN:-}" ]; then
    param DomainName "$CODE2_DOMAIN"
    zone=$(find_zone "$CODE2_DOMAIN"); param HostedZoneId "$zone"
    cert=$(find_cert "$CODE2_DOMAIN"); param CertificateArn "$cert"
  fi
  [ -z "${CODE2_RESTORE_SNAPSHOT:-}" ] || param DataSnapshotId "$CODE2_RESTORE_SNAPSHOT"

  for pair in $TUNABLES; do
    k=${pair%%:*} v=${pair#*:}
    if is_set "$v"; then param "$k" "${!v}"; fi
  done
  echo "create $STACK in $AWS_REGION ($caller): $type $arch in $az${CODE2_DOMAIN:+, https://$CODE2_DOMAIN}"
}

params_update() {
  local existing pair k v cur_type new_type cur_arch new_arch ami pl
  existing=" $(aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].Parameters[].ParameterKey' --output text | tr '\t' ' ') "
  has() { [[ "$existing" == *" $1 "* ]]; }

  for pair in $TUNABLES; do
    k=${pair%%:*} v=${pair#*:}
    if is_set "$v"; then param "$k" "${!v}"; elif has "$k"; then keep "$k"; fi
  done
  pl=$(prefix_list); param CloudFrontPrefixListId "$pl"   # always current; older stacks lack it
  for k in $CREATE_ONLY; do
    if has "$k"; then keep "$k"
    elif [ "$k" = WaitForBoot ]; then param WaitForBoot false   # the running instance predates the boot signal
    fi
  done
  if has OriginSlot; then keep OriginSlot; fi
  for v in CODE2_DOMAIN CODE2_AZ CODE2_VPC_ID CODE2_SUBNET_ID CODE2_RESTORE_SNAPSHOT; do
    [ -z "${!v:-}" ] || warn "$v only applies when the stack is created; ignored"
  done

  # A new AMI replaces the instance (the replacement attaches /home once CloudFormation terminates the old one).
  cur_type=$(aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Parameters[?ParameterKey=='InstanceType'].ParameterValue" --output text)
  new_type=${CODE2_INSTANCE_TYPE:-$cur_type}
  cur_arch=$(arch_of "$cur_type"); new_arch=$(arch_of "$new_type")
  [ -n "$new_arch" ] || die "unknown instance type $new_type in $AWS_REGION"
  if [ "${CODE2_UPDATE_AMI:-}" = 1 ] || [ "$cur_arch" != "$new_arch" ]; then
    [ "$cur_arch" = "$new_arch" ] || echo "$cur_type ($cur_arch) -> $new_type ($new_arch): the instance is replaced with a $new_arch AMI"
    ami=$(latest_ami "$new_arch"); param ImageId "$ami"
  else
    keep ImageId
  fi
  echo "update $STACK in $AWS_REGION ($caller)"
}

# ---------- migration from the template with AWS::EC2::VolumeAttachment ----------
# Removing that resource would detach the mounted /home. Step 1 re-deploys the running template with the attachment
# retained; step 2 (the normal plan) then drops it from the stack while the volume stays attached.
MIGRATION_MARK=MigrationKeepsDataVolumeAttachment
legacy_template() {
  aws cloudformation get-template --stack-name "$STACK" --template-stage Original --query TemplateBody --output text
}

# ---------- change sets ----------
# make_change_set <type> <template> <kind>: creates change set $cs from $PARAMS; fails when it has no changes.
make_change_set() {
  local status reason
  echo "$PARAMS" > "$TMP/params.json"
  cs="$STACK-$(date -u +%Y%m%d-%H%M%S)-$RANDOM"
  aws cloudformation create-change-set --stack-name "$STACK" --change-set-name "$cs" --change-set-type "$1" \
    --template-body "file://$2" --capabilities CAPABILITY_IAM --tags Key=project,Value=code2 \
    --parameters "file://$TMP/params.json" --description "code2 $3 sha256=$(sha256 "$2")" \
    --query Id --output text >/dev/null
  aws cloudformation wait change-set-create-complete --stack-name "$STACK" --change-set-name "$cs" 2>/dev/null || true
  read -r status reason < <(aws cloudformation describe-change-set --stack-name "$STACK" --change-set-name "$cs" \
    --query '[Status,StatusReason]' --output text)
  if [ "$status" = FAILED ]; then
    aws cloudformation delete-change-set --stack-name "$STACK" --change-set-name "$cs"
    [[ "$reason" == *"didn't contain changes"* || "$reason" == *"No updates are to be performed"* ]] && return 1
    die "change set failed: $reason"
  fi
}

# recreates_instance <change set>: the change set may replace the instance (any property needing recreation).
recreates_instance() {
  aws cloudformation describe-change-set --stack-name "$STACK" --change-set-name "$1" --output json | jq -e \
    '[.Changes[].ResourceChange | select(.LogicalResourceId == "Instance") | .Details[].Target.RequiresRecreation
      | select(. != "Never")] | length > 0' >/dev/null
}

plan() {
  local type template kind cs
  check_state
  case "$(stack_status)" in NONE|REVIEW_IN_PROGRESS|DELETE_COMPLETE) type=CREATE ;; *) type=UPDATE ;; esac
  template=$TEMPLATE kind=main

  if [ "$type" = UPDATE ] && has_resource DataVolumeAttachment; then
    legacy_template > "$TMP/deployed.yaml"
    if ! grep -q "$MIGRATION_MARK" "$TMP/deployed.yaml"; then
      kind=migrate template=$TMP/migrate.yaml
      awk '{ print } /Type: AWS::EC2::VolumeAttachment/ { print "    DeletionPolicy: Retain"; print "    UpdateReplacePolicy: Retain" }' "$TMP/deployed.yaml" > "$template"
      printf '  %s:\n    Value: "true"\n' "$MIGRATION_MARK" >> "$template"
      PARAMS=$(aws cloudformation describe-stacks --stack-name "$STACK" --output json \
        | jq -c '[.Stacks[0].Parameters[] | {ParameterKey, UsePreviousValue: true}]')
      echo "migration step 1/2: keep the /home volume attachment when it leaves the template (no resource changes)"
    else
      echo "migration step 2/2: the stack moves to the current template; the /home volume stays attached"
      params_update
    fi
  elif [ "$type" = UPDATE ]; then
    params_update
  else
    params_create
  fi

  make_change_set "$type" "$template" "$kind" || { echo "no changes"; return 0; }

  # A VPC origin in use cannot move to another instance: when the instance is recreated, plan again with the other
  # origin slot, so CloudFormation makes a new origin, moves the distribution and deletes the old one.
  if [ "$kind" = main ] && [ "$type" = UPDATE ] && recreates_instance "$cs"; then
    local slot
    slot=$(aws cloudformation describe-stacks --stack-name "$STACK" \
      --query "Stacks[0].Parameters[?ParameterKey=='OriginSlot'].ParameterValue" --output text)
    [ "$slot" = b ] && slot=a || slot=b
    echo "the instance is replaced: the distribution moves to VPC origin slot $slot"
    aws cloudformation delete-change-set --stack-name "$STACK" --change-set-name "$cs"
    PARAMS=$(jq -c --arg s "$slot" 'map(select(.ParameterKey != "OriginSlot")) + [{ParameterKey: "OriginSlot", ParameterValue: $s}]' <<<"$PARAMS")
    make_change_set "$type" "$template" "$kind" || die "the slot change set unexpectedly had no changes"
  fi

  echo "change set $cs ($type $STACK):"
  aws cloudformation describe-change-set --stack-name "$STACK" --change-set-name "$cs" \
    --query 'Changes[].ResourceChange.[Action,LogicalResourceId,ResourceType,Replacement]' --output table
  if [ "$kind" = main ] && [ "$type" = UPDATE ] && has_resource DataVolumeAttachment; then
    echo "after apply, run infra/deploy.sh reconfigure once: the running instance still has the old setup"
  fi
  echo "apply it with: infra/deploy.sh stack apply"
}

apply() {
  local cs desc type rollback=()
  read -r cs desc < <(aws cloudformation list-change-sets --stack-name "$STACK" --output json | jq -r \
    '[.Summaries[] | select(.Status == "CREATE_COMPLETE" and .ExecutionStatus == "AVAILABLE")] | sort_by(.CreationTime) | last
     | select(.) | [.ChangeSetName, (.Description // "")] | @tsv') || true
  [ -n "${cs:-}" ] || die "no pending change set for $STACK; run plan first"
  # A plan of an older template must not be applied over a newer checkout.
  if [[ "$desc" == "code2 main sha256="* ]] && [ "${desc#*sha256=}" != "$(sha256 "$TEMPLATE")" ]; then
    die "infra/code2.yaml changed after $cs was planned; run plan again"
  fi
  type=$( [ "$(stack_status)" = REVIEW_IN_PROGRESS ] && echo create || echo update )
  [ "${CODE2_KEEP_ON_FAILURE:-}" != 1 ] || rollback=(--disable-rollback)
  echo "executing $cs"
  aws cloudformation execute-change-set --stack-name "$STACK" --change-set-name "$cs" ${rollback[@]+"${rollback[@]}"}
  if ! aws cloudformation wait "stack-$type-complete" --stack-name "$STACK"; then
    aws cloudformation describe-stack-events --stack-name "$STACK" --max-items 30 \
      --query 'StackEvents[?contains(ResourceStatus,`FAILED`)].[LogicalResourceId,ResourceStatusReason]' --output table
    die "$STACK: $(stack_status)"
  fi
  echo "$STACK: $(stack_status)"
  if [[ "$desc" == "code2 migrate"* ]]; then echo "now run infra/deploy.sh stack plan again for step 2"; fi
}

# ---------- instance helpers ----------
load_outputs() {
  local o
  o=$(aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].Outputs' --output json 2>/dev/null || echo null)
  [ "$o" != null ] || die "$STACK has no outputs (status $(stack_status))"
  out() { jq -r --arg k "$1" '.[] | select(.OutputKey == $k).OutputValue' <<<"$o"; }
  INSTANCE=$(out InstanceId) IP=$(out InstancePrivateIp) EICE=$(out InstanceConnectEndpointId)
  URL=$(out Url) LOGOUT=$(out LogoutUrl) LOG_GROUP=$(out LogGroupName)
}
instance_state() { aws ec2 describe-instances --instance-ids "$INSTANCE" --query 'Reservations[0].Instances[0].State.Name' --output text; }

# ssm_run <command...>: runs commands as root on the instance, prints stdout, fails with the command.
ssm_run() {
  local id st=Pending
  [ "$(instance_state)" = running ] || die "$INSTANCE is $(instance_state)"
  aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE" \
    --query 'InstanceInformationList[0].PingStatus' --output text | grep -q Online || die "$INSTANCE is not online in Systems Manager yet"
  id=$(aws ssm send-command --instance-ids "$INSTANCE" --document-name AWS-RunShellScript \
    --parameters "$(jq -nc '{commands: $ARGS.positional, executionTimeout: ["3600"]}' --args "$@")" \
    --query Command.CommandId --output text)
  while [[ "$st" =~ ^(Pending|InProgress|Delayed)$ ]]; do
    sleep 3
    st=$(aws ssm get-command-invocation --command-id "$id" --instance-id "$INSTANCE" --query Status --output text 2>/dev/null || echo Pending)
  done
  aws ssm get-command-invocation --command-id "$id" --instance-id "$INSTANCE" --query StandardOutputContent --output text
  [ "$st" = Success ] || { aws ssm get-command-invocation --command-id "$id" --instance-id "$INSTANCE" \
    --query StandardErrorContent --output text >&2; die "command $st"; }
}

# One-off key: EC2 Instance Connect accepts it for 60 seconds, then the tunnel goes through the EICE. The host key
# alias includes the instance id, so a replaced instance does not clash with the old one's key.
ssh_instance() {
  load_outputs
  local key=${CODE2_SSH_KEY:-$HOME/.ssh/id_ed25519}
  [ -f "$key" ] || ssh-keygen -q -t ed25519 -N "" -f "$key"
  aws ec2-instance-connect send-ssh-public-key --instance-id "$INSTANCE" --instance-os-user ec2-user \
    --ssh-public-key "file://$key.pub" --query Success --output text >/dev/null
  exec ssh -i "$key" -o StrictHostKeyChecking=accept-new -o HostKeyAlias="$STACK-$INSTANCE" \
    -o ProxyCommand="aws ec2-instance-connect open-tunnel --instance-connect-endpoint-id $EICE --private-ip-address $IP --remote-port 22" \
    "ec2-user@$IP" "$@"
}

destroy() {
  local s pool vol ans
  s=$(stack_status)
  [ "$s" != NONE ] || die "no stack $STACK in $AWS_REGION"
  pool=$(physical_id UserPool) vol=$(physical_id DataVolume)
  if [ "${CODE2_YES:-}" != 1 ]; then
    read -rp "delete stack $STACK ($s) in $AWS_REGION, account $caller? type the stack name: " ans
    [ "$ans" = "$STACK" ] || die "not deleted"
  fi
  aws cloudformation delete-stack --stack-name "$STACK"
  if ! aws cloudformation wait stack-delete-complete --stack-name "$STACK"; then
    aws cloudformation describe-stack-events --stack-name "$STACK" --max-items 20 \
      --query 'StackEvents[?contains(ResourceStatus,`FAILED`)].[LogicalResourceId,ResourceStatusReason]' --output table
    die "delete did not finish; a CloudFront-VPCOrigins-Service-SG that lingers in the VPC clears after a while: run destroy again"
  fi
  echo "$STACK deleted. Left behind on purpose:"
  if [ -n "$pool" ] && [ "$pool" != None ]; then
    echo "- user pool $pool (retained, deletion protection). To remove it:"
    echo "    aws cognito-idp update-user-pool --user-pool-id $pool --deletion-protection INACTIVE"
    echo "    aws cognito-idp delete-user-pool --user-pool-id $pool"
  fi
  if [ -n "$vol" ] && [ "$vol" != None ]; then
    echo "- /home snapshots of $vol (the final one and daily backups); restore with CODE2_RESTORE_SNAPSHOT:"
    aws ec2 describe-snapshots --owner-ids self --filters "Name=volume-id,Values=$vol" \
      --query 'reverse(sort_by(Snapshots,&StartTime))[].[SnapshotId,StartTime,VolumeSize,State]' --output table
  fi
}

case "$1" in
  stack)
    case "${2:-}" in
      plan) plan ;;
      apply) apply ;;
      *) usage ;;
    esac ;;
  status)
    load_outputs
    echo "url:      $URL"
    [ -z "$LOGOUT" ] || echo "logout:   $LOGOUT"
    state=$(instance_state)
    echo "instance: $INSTANCE ($IP) $state"
    if [ "$state" = running ]; then
      ssm_run "systemctl is-active code-server oauth2-proxy | paste -sd' '" "df -h /home | tail -1" \
        "readlink -f /usr/local/bin/code-server /usr/local/bin/oauth2-proxy" || true
    fi ;;
  logs)
    load_outputs
    [ -n "$LOG_GROUP" ] || die "no log group yet (run stack plan/apply, then reconfigure)"
    follow=(); since=1h
    for a in "${@:2}"; do if [ "$a" = -f ]; then follow=(--follow); else since=$a; fi; done
    aws logs tail "$LOG_GROUP" --since "$since" ${follow[@]+"${follow[@]}"} ;;
  reconfigure)
    load_outputs
    echo "running the current user data on $INSTANCE (no restart; services restart only if their setup changed)"
    ssm_run 't=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")' \
      'curl -fsS -H "X-aws-ec2-metadata-token: $t" http://169.254.169.254/latest/user-data > /run/code2-userdata' \
      'bash /run/code2-userdata > /dev/null 2>&1 || { tail -n 30 /var/log/code2-setup.log; exit 1; }' \
      'tail -n 5 /var/log/code2-setup.log' ;;
  ssh) shift; ssh_instance "$@" ;;
  ssh-config)
    load_outputs
    key=${CODE2_SSH_KEY:-$HOME/.ssh/id_ed25519}
    cat <<EOF
# push a key first (valid 60 s); regenerate this block if the instance is replaced:
#   aws ec2-instance-connect send-ssh-public-key --region $AWS_REGION --instance-id $INSTANCE --instance-os-user ec2-user --ssh-public-key file://$key.pub
Host $STACK
  HostName $IP
  User ec2-user
  IdentityFile $key
  HostKeyAlias $STACK-$INSTANCE
  ProxyCommand aws ec2-instance-connect open-tunnel --region $AWS_REGION --instance-connect-endpoint-id $EICE --private-ip-address %h --remote-port %p
EOF
    ;;
  shell) load_outputs; aws ssm start-session --target "$INSTANCE" ;;
  stop) load_outputs; aws ec2 stop-instances --instance-ids "$INSTANCE" --query 'StoppingInstances[0].CurrentState.Name' --output text ;;
  start) load_outputs; aws ec2 start-instances --instance-ids "$INSTANCE" --query 'StartingInstances[0].CurrentState.Name' --output text ;;
  destroy) destroy ;;
  *) usage ;;
esac
