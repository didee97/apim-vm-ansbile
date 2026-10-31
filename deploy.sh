#!/usr/bin/env bash
# One-command deploy of WSO2 APIM HA (4 VMs).
#
#   ./deploy.sh                 first run asks questions, then deploys
#   ./deploy.sh --reconfigure   ask the questions again, then deploy
#   ./deploy.sh --check         ping all VMs only (after configuring)
#   ./deploy.sh --healthcheck   run healthcheck.yml only: PASS/FAIL for every service
#   ./deploy.sh --logs          collect diagnostics (service state, memory, APIM errors) from every VM
#   ./deploy.sh -- <args>       extra ansible-playbook args, e.g. -- --tags nginx
set -euo pipefail
cd "$(dirname "$0")"

reconfigure=false check=false healthcheck=false logs=false extra=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reconfigure) reconfigure=true ;;
    --check)       check=true ;;
    --healthcheck) healthcheck=true ;;
    --logs)        logs=true ;;
    --)            shift; extra=("$@"); break ;;
    -h|--help)     sed -n '2,10p' "$0"; exit 0 ;;
    *)             echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# shellcheck source=scripts/ensure-ansible.sh
source scripts/ensure-ansible.sh
ensure_ansible

if $reconfigure || [[ ! -f group_vars/all/10-config.yml || ! -f inventory/hosts.ini ]]; then
  ./configure.sh
fi

# shellcheck disable=SC1091
[[ -f .deploy.env ]] && source .deploy.env
ask_ssh=${ANSIBLE_ASK_PASS:-False} ask_sudo=${ANSIBLE_BECOME_ASK_PASS:-False}
# We ask once below and hand the answers to every Ansible run, so Ansible must not prompt itself
unset ANSIBLE_ASK_PASS ANSIBLE_BECOME_ASK_PASS

if [[ $ask_ssh == True ]] && ! command -v sshpass >/dev/null; then
  echo "SSH password login needs 'sshpass' on this machine:  sudo apt install sshpass   (or use SSH keys: ssh-copy-id <user>@<vm>)" >&2
  exit 1
fi

# Passwords are asked once, then handed to every Ansible run through a private
# file (mode 600) in your RAM-backed runtime folder, deleted when this script ends.
ssh_pw='' sudo_pw='' vault_pw=''
if [[ $ask_ssh == True ]]; then
  read -rsp "SSH password for $(awk -F= '/^ansible_user=/{print $2}' inventory/hosts.ini) on the VMs: " ssh_pw; echo
fi
if [[ $ask_sudo == True ]]; then
  if [[ $ask_ssh == True ]]; then
    read -rsp "sudo password [Enter = same as SSH password]: " sudo_pw; echo
    sudo_pw=${sudo_pw:-$ssh_pw}
  else
    read -rsp "sudo password on the VMs: " sudo_pw; echo
  fi
fi
if head -1 group_vars/all/20-secrets.yml 2>/dev/null | grep -q '^\$ANSIBLE_VAULT'; then
  read -rsp "Vault password (for group_vars/all/20-secrets.yml): " vault_pw; echo
fi

pw_args=()
if [[ -n $ssh_pw$sudo_pw$vault_pw ]]; then
  secrets_dir=$(umask 077 && mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/apim-deploy.XXXXXX")
  trap 'rm -rf -- "$secrets_dir"' EXIT
  if [[ -n $ssh_pw$sudo_pw ]]; then
    (umask 077 && SSH_PW=$ssh_pw SUDO_PW=$sudo_pw python3 -c 'import json, os
d = {}
if os.environ["SSH_PW"]: d["ansible_password"] = os.environ["SSH_PW"]
if os.environ["SUDO_PW"]: d["ansible_become_password"] = os.environ["SUDO_PW"]
print(json.dumps(d))' > "$secrets_dir/login.json")
    pw_args+=(-e "@$secrets_dir/login.json")
  fi
  if [[ -n $vault_pw ]]; then
    (umask 077 && printf '%s\n' "$vault_pw" > "$secrets_dir/vault.txt")
    pw_args+=(--vault-password-file "$secrets_dir/vault.txt")
  fi
fi
unset ssh_pw sudo_pw vault_pw

# Runs an Ansible command with the passwords above
run() { "$@" "${pw_args[@]}"; }

echo "==> Checking SSH access to all VMs"
run ansible all -m ansible.builtin.ping
$check && exit 0

if $logs; then
  echo "==> Collecting diagnostics (read-only)"
  run ansible-playbook diagnose.yml
  exit
fi

if $healthcheck; then
  echo "==> Health check"
  run ansible-playbook healthcheck.yml "${extra[@]}"
  exit
fi

echo "==> Deploying"
run ansible-playbook site.yml "${extra[@]}"

# A dry run (-- --check) changed nothing, so there is nothing new to health-check
if [[ " ${extra[*]} " == *" --check "* ]]; then
  echo "==> Dry run finished: nothing was changed on the VMs."
  exit 0
fi

echo "==> Health check"
run ansible-playbook healthcheck.yml
