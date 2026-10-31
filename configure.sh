#!/usr/bin/env bash
# Asks the deployment questions step by step, shows a review, then saves the
# answers with configure.yml. Run again any time to change settings
# (current values are kept when you press Enter).
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck source=scripts/ensure-ansible.sh
source scripts/ensure-ansible.sh
ensure_ansible >/dev/null

# The Python that runs Ansible has PyYAML (and cryptography for the cert check)
python=$(ansible --version | sed -n 's/^ *python version = .*(\([^()]*\))$/\1/p')
[[ -x $python ]] || python=python3

# Answers (including passwords) only live in a private RAM folder while saving
tmp=$(umask 077 && mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/apim-configure.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

"$python" scripts/configure.py "$tmp/answers.json" || exit 1

echo
echo "Saving..."
if ansible-playbook configure.yml -e "@$tmp/answers.json" > "$tmp/save.log" 2>&1; then
  echo "Saved:"
  echo "  inventory/hosts.ini            (the 4 VMs)"
  echo "  group_vars/all/10-config.yml   (settings)"
  echo "  group_vars/all/20-secrets.yml  (passwords, only readable by you)"
  echo
  echo "Next: ./deploy.sh"
else
  echo "Could not save the settings:" >&2
  grep -vE '^\s*$' "$tmp/save.log" | tail -25 >&2
  exit 1
fi
