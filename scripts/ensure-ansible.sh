# Sourced by deploy.sh and test/lab/lab.sh: makes ansible-core 2.18+ and the
# required collections available, installing them into <repo>/.venv if needed.
# No sudo, and the system Python is left alone (Ubuntu 24.04 blocks pip --user).

ensure_ansible() {
  local repo; repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local venv="$repo/.venv"

  _ansible_ok() {
    command -v ansible-playbook >/dev/null 2>&1 || return 1
    ansible --version 2>/dev/null | head -1 | python3 -c '
import re, sys
m = re.search(r"(\d+)\.(\d+)", sys.stdin.read())
sys.exit(0 if m and tuple(map(int, m.groups())) >= (2, 18) else 1)'
  }

  [[ -x "$venv/bin/ansible-playbook" ]] && export PATH="$venv/bin:$PATH"
  if ! _ansible_ok; then
    echo "==> Installing Ansible into $venv (one time, ~1 min)"
    if ! python3 -m venv "$venv" 2>/dev/null; then
      echo "Python venv support is missing. Install it with:  sudo apt install python3-venv" >&2
      return 1
    fi
    "$venv/bin/pip" install -q --upgrade pip
    # cryptography: community.crypto builds the self-signed certificate on this machine
    "$venv/bin/pip" install -q 'ansible-core>=2.18' cryptography
    export PATH="$venv/bin:$PATH"
    _ansible_ok || { echo "Ansible install failed" >&2; return 1; }
  fi

  if [[ -z "${_ANSIBLE_COLLECTIONS_DONE:-}" ]]; then
    echo "==> Checking Ansible collections"
    ansible-galaxy collection install -r "$repo/requirements.yml" >/dev/null
    export _ANSIBLE_COLLECTIONS_DONE=1
  fi
}
