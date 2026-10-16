#!/usr/bin/env bash
# code2 operations. Infrastructure goes through CloudFormation change sets (plan, look, then apply).
#
#   infra/deploy.sh stack plan|apply   code2 stack (infra/code2.yaml)
#   infra/deploy.sh status             instance state, services and the URL
#   infra/deploy.sh ssh [args]         SSH as ec2-user through the stack's EICE (one-off key via EC2 Instance Connect)
#   infra/deploy.sh ssh-config         ~/.ssh/config block for ssh / VS Code Remote-SSH (keys must be pushed per use)
#   infra/deploy.sh shell              Session Manager shell on the instance
#   infra/deploy.sh stop|start         stop or start the instance (the NAT gateway keeps billing while stopped)
#
# Settings (environment):
#   CODE2_ADMIN_EMAIL   required on the first plan: where Cognito sends the temporary password
#   CODE2_ADMIN_USER    sign-in name (default admin)
#   CODE2_DOMAIN        optional custom name, e.g. code.example.com (needs a Route 53 zone and a us-east-1 ACM cert)
#   CODE2_ZONE          hosted zone of CODE2_DOMAIN (default: CODE2_DOMAIN without its first label)
#   CODE2_STACK         stack name, lowercase (default code2)
#   CODE2_ACCOUNT       optional: refuse to run with credentials for any other account
#   AWS_REGION          default ap-northeast-2
set -euo pipefail
export AWS_REGION=${AWS_REGION:-ap-northeast-2}
STACK=${CODE2_STACK:-code2}
DOMAIN=${CODE2_DOMAIN:-}
ZONE_NAME=${CODE2_ZONE:-${DOMAIN#*.}}
ADMIN_USER=${CODE2_ADMIN_USER:-admin}
ADMIN_EMAIL=${CODE2_ADMIN_EMAIL:-}
TEMPLATE=$(dirname "$0")/code2.yaml

usage() { sed -n '2,19p' "$0"; exit 2; }

caller=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo none)
if [ "$caller" = none ]; then
  echo "no AWS credentials: sign in first (aws login, aws sso login, or AWS_PROFILE=...)"
  exit 1
fi
if [ -n "${CODE2_ACCOUNT:-}" ] && [ "$caller" != "$CODE2_ACCOUNT" ]; then
  echo "refusing to run: credentials are for account $caller, CODE2_ACCOUNT is $CODE2_ACCOUNT"
  exit 1
fi

# ---------- CloudFormation change sets ----------
stack_status() { aws cloudformation describe-stacks --stack-name "$1" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE; }

plan() {  # plan <stack> <template> <parameters...>
  local name=$1 template=$2; shift 2
  local type=UPDATE cs status
  case "$(stack_status "$name")" in
    NONE|REVIEW_IN_PROGRESS) type=CREATE ;;
    *_IN_PROGRESS) echo "$name is busy: $(stack_status "$name")"; exit 1 ;;
  esac
  cs="$name-$(date -u +%Y%m%d-%H%M%S)"
  aws cloudformation create-change-set --stack-name "$name" --change-set-name "$cs" --change-set-type "$type" \
    --template-body "file://$template" --capabilities CAPABILITY_IAM \
    --tags Key=project,Value=code2 --parameters "$@" --query Id --output text >/dev/null
  aws cloudformation wait change-set-create-complete --stack-name "$name" --change-set-name "$cs" 2>/dev/null || true
  status=$(aws cloudformation describe-change-set --stack-name "$name" --change-set-name "$cs" --query '[Status,StatusReason]' --output text)
  if [[ "$status" == FAILED* ]]; then
    echo "$status"
    aws cloudformation delete-change-set --stack-name "$name" --change-set-name "$cs"
    return 0
  fi
  echo "change set $cs ($type $name):"
  aws cloudformation describe-change-set --stack-name "$name" --change-set-name "$cs" \
    --query 'Changes[].ResourceChange.[Action,LogicalResourceId,ResourceType,Replacement]' --output table
  echo "apply it with: infra/deploy.sh stack apply"
}

apply() {  # apply <stack>: executes the newest pending change set
  local name=$1 cs type
  read -r cs _ < <(aws cloudformation list-change-sets --stack-name "$name" \
    --query 'reverse(sort_by(Summaries[?Status==`CREATE_COMPLETE` && ExecutionStatus==`AVAILABLE`], &CreationTime))[0].[ChangeSetName,ChangeSetId]' \
    --output text)
  [ -n "$cs" ] && [ "$cs" != None ] || { echo "no pending change set for $name; run plan first"; exit 1; }
  type=$( [ "$(stack_status "$name")" = REVIEW_IN_PROGRESS ] && echo create || echo update )
  echo "executing $cs"
  aws cloudformation execute-change-set --stack-name "$name" --change-set-name "$cs"
  if ! aws cloudformation wait "stack-$type-complete" --stack-name "$name"; then
    aws cloudformation describe-stack-events --stack-name "$name" --max-items 20 \
      --query 'StackEvents[?contains(ResourceStatus,`FAILED`)].[LogicalResourceId,ResourceStatusReason]' --output table
    exit 1
  fi
  echo "$name: $(stack_status "$name")"
}

lookup() { local v; v=$("$@"); [ -n "$v" ] && [ "$v" != None ] || { echo "lookup failed: ${*:2}" >&2; exit 1; }; echo "$v"; }

stack_params() {
  if [ "$(stack_status "$STACK")" = NONE ]; then
    [ -n "$ADMIN_EMAIL" ] || { echo "set CODE2_ADMIN_EMAIL (the temporary password goes there)" >&2; exit 1; }
    local ami zone cert out
    ami=$(lookup aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 --query Parameter.Value --output text)
    out="ParameterKey=ImageId,ParameterValue=$ami ParameterKey=AdminUsername,ParameterValue=$ADMIN_USER"
    out+=" ParameterKey=AdminEmail,ParameterValue=$ADMIN_EMAIL"
    if [ -n "$DOMAIN" ]; then   # without these the template defaults to the CloudFront domain
      zone=$(lookup aws route53 list-hosted-zones-by-name --dns-name "$ZONE_NAME" --max-items 1 \
        --query "HostedZones[?Name=='$ZONE_NAME.'].Id | [0]" --output text)
      cert=$(lookup aws acm list-certificates --region us-east-1 --certificate-statuses ISSUED \
        --query "CertificateSummaryList[?DomainName=='*.$ZONE_NAME' || DomainName=='$DOMAIN'].CertificateArn | [0]" --output text)
      out+=" ParameterKey=DomainName,ParameterValue=$DOMAIN ParameterKey=HostedZoneId,ParameterValue=${zone#/hostedzone/}"
      out+=" ParameterKey=CertificateArn,ParameterValue=$cert"
    fi
    echo "$out"
  else
    # ImageId stays: a new AMI replaces the instance. AdminUsername follows ADMIN_USER: a new name recreates the user
    # (Cognito cannot rename) and emails a new temporary password; AdminEmail stays.
    local k out=""
    for k in VpcCidr PublicSubnetCidr PrivateSubnetCidr DomainName HostedZoneId CertificateArn ImageId InstanceType \
             DataVolumeSize CodeServerVersion OAuth2ProxyVersion AdminEmail; do
      out+=" ParameterKey=$k,UsePreviousValue=true"
    done
    echo "$out ParameterKey=AdminUsername,ParameterValue=$ADMIN_USER"
  fi
}

load_outputs() {
  local o
  o=$(aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].Outputs' --output json)
  INSTANCE=$(jq -r '.[] | select(.OutputKey=="InstanceId").OutputValue' <<<"$o")
  IP=$(jq -r '.[] | select(.OutputKey=="InstancePrivateIp").OutputValue' <<<"$o")
  EICE=$(jq -r '.[] | select(.OutputKey=="InstanceConnectEndpointId").OutputValue' <<<"$o")
  URL=$(jq -r '.[] | select(.OutputKey=="Url").OutputValue' <<<"$o")
}

# One-off key: EC2 Instance Connect accepts it for 60 seconds, then the tunnel goes through the stack's EICE.
ssh_instance() {
  load_outputs
  local key=${CODE2_SSH_KEY:-$HOME/.ssh/id_ed25519}
  [ -f "$key" ] || ssh-keygen -q -t ed25519 -N "" -f "$key"
  aws ec2-instance-connect send-ssh-public-key --instance-id "$INSTANCE" --instance-os-user ec2-user \
    --ssh-public-key "file://$key.pub" --query Success --output text >/dev/null
  exec ssh -i "$key" -o StrictHostKeyChecking=accept-new -o HostKeyAlias="$STACK" \
    -o ProxyCommand="aws ec2-instance-connect open-tunnel --instance-connect-endpoint-id $EICE --private-ip-address $IP --remote-port 22" \
    "ec2-user@$IP" "$@"
}

case "${1:-}" in
  stack)
    case "${2:-}" in
      plan) read -ra params < <(stack_params); plan "$STACK" "$TEMPLATE" "${params[@]}" ;;
      apply) apply "$STACK" ;;
      *) usage ;;
    esac ;;
  status)
    load_outputs
    echo "url:      $URL"
    echo "instance: $INSTANCE ($IP) $(aws ec2 describe-instances --instance-ids "$INSTANCE" --query 'Reservations[0].Instances[0].State.Name' --output text)"
    aws ssm send-command --instance-ids "$INSTANCE" --document-name AWS-RunShellScript \
      --parameters 'commands=["systemctl is-active code-server oauth2-proxy","df -h /home | tail -1","readlink -f /usr/local/bin/code-server"]' \
      --query Command.CommandId --output text | {
        read -r id; aws ssm wait command-executed --command-id "$id" --instance-id "$INSTANCE" 2>/dev/null || true
        aws ssm get-command-invocation --command-id "$id" --instance-id "$INSTANCE" --query StandardOutputContent --output text; } ;;
  ssh) shift; ssh_instance "$@" ;;
  ssh-config)
    load_outputs
    cat <<EOF
# push a key first (valid 60 s):
#   aws ec2-instance-connect send-ssh-public-key --region $AWS_REGION --instance-id $INSTANCE --instance-os-user ec2-user --ssh-public-key file://~/.ssh/id_ed25519.pub
Host $STACK
  HostName $IP
  User ec2-user
  IdentityFile ~/.ssh/id_ed25519
  ProxyCommand aws ec2-instance-connect open-tunnel --region $AWS_REGION --instance-connect-endpoint-id $EICE --private-ip-address %h --remote-port %p
EOF
    ;;
  shell) load_outputs; aws ssm start-session --target "$INSTANCE" ;;
  stop) load_outputs; aws ec2 stop-instances --instance-ids "$INSTANCE" --query 'StoppingInstances[0].CurrentState.Name' --output text ;;
  start) load_outputs; aws ec2 start-instances --instance-ids "$INSTANCE" --query 'StartingInstances[0].CurrentState.Name' --output text ;;
  *) usage ;;
esac
