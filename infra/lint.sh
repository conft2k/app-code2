#!/usr/bin/env bash
# Static checks: cfn-lint on the template, shellcheck on deploy.sh and on the instance user data (its
# CloudFormation ${...} references replaced by placeholders). Needs cfn-lint (pip) and shellcheck.
set -euo pipefail
cd "$(dirname "$0")"
cfn-lint code2.yaml
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
echo "lint ok"
