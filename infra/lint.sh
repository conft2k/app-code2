#!/usr/bin/env bash
# Static checks: cfn-lint on the template, shellcheck on deploy.sh and on the instance user data (its
# CloudFormation ${...} references replaced by placeholders). Needs cfn-lint (pip) and shellcheck.
set -euo pipefail
cd "$(dirname "$0")"
cfn-lint code2.yaml
# CloudFormation takes a template body of at most 51,200 bytes.
size=$(wc -c < code2.yaml)
[ "$size" -le 51200 ] || { echo "code2.yaml is $size bytes; the template body limit is 51,200" >&2; exit 1; }
shellcheck --severity=warning deploy.sh lint.sh
python3 - code2.yaml > "${TMPDIR:-/tmp}/code2-userdata.sh" <<'PY'
import re, sys, yaml

class Loader(yaml.SafeLoader):
    pass

def tag(loader, suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return {suffix: loader.construct_scalar(node)}
    if isinstance(node, yaml.SequenceNode):
        return {suffix: loader.construct_sequence(node, deep=True)}
    return {suffix: loader.construct_mapping(node, deep=True)}

Loader.add_multi_constructor("!", tag)
doc = yaml.load(open(sys.argv[1]), Loader=Loader)
script = doc["Resources"]["Instance"]["Properties"]["UserData"]["Fn::Base64"]["Sub"][0]
script = script.replace("${!", "\0")
script = re.sub(r"\$\{[A-Za-z0-9:]+\}", "CFN_VALUE", script)
print(script.replace("\0", "${"), end="")
PY
shellcheck --severity=warning --shell=bash "${TMPDIR:-/tmp}/code2-userdata.sh"

# Public repository: no real account ids, resource ids, addresses or domains; examples use example.com.
files=$(git -C .. ls-files | grep -vE '\.(png|jpg|ico)$')
leaks=$(cd .. && echo "$files" | tr '\n' '\0' | xargs -0 grep -nIE \
  -e '[^0-9][0-9]{12}([^0-9]|$)' -e '^[0-9]{12}([^0-9]|$)' \
  -e '(^|[^a-z])(vpc|subnet|sg|i|vol|snap|eice|nat|igw|rtb|vpce|pcx|ami|eipalloc|pl)-[0-9a-f]{8,17}([^0-9a-f]|$)' \
  -e '[a-z]{2}-[a-z]+-[0-9]_[A-Za-z0-9]{9}' \
  -e '(^|[^a-z0-9])d[a-z0-9]{13}\.cloudfront\.net' \
  -e '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+' || true)
leaks=$(grep -vE '@(example\.(com|org|net)|verificationemail\.com)' <<<"$leaks" || true)
hosts=$(cd .. && echo "$files" | tr '\n' '\0' | xargs -0 grep -ohIE '([A-Za-z0-9-]+\.)+(com|net|org|io|dev|app|me|ai|kr|jp|cloud|xyz)([^A-Za-z0-9-]|$)' \
  | sed -E 's/[^A-Za-z0-9.-]+$//; s/\.+$//' | sort -u \
  | grep -vE '(^|\.)(example\.(com|net|org)|amazonaws\.com|amazon\.com|amazoncognito\.com|cloudfront\.net|github\.com|githubusercontent\.com|w3\.org|draw\.io|verificationemail\.com)$' || true)
if [ -n "$leaks$hosts" ]; then
  echo "possible personal data (use example.com, placeholders like vpc-0123...):" >&2
  printf '%s\n' "$leaks" "$hosts" | sed '/^$/d' >&2
  exit 1
fi
echo "lint ok"
