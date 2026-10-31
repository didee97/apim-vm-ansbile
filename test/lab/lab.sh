#!/usr/bin/env bash
# Test the playbook without real VMs: 4 Ubuntu 22.04 containers with systemd
# and SSH act as the db, lb, apim1 and apim2 VMs.
#
# One command for everything:
#   test/lab/lab.sh test                      full test: postgres+Fluent Bit, mysql, mssql
#   test/lab/lab.sh test mysql                only some: postgres | postgres+fb | mysql | mssql
#   test/lab/lab.sh destroy                   remove containers, images and downloaded files
#
# Step by step:
#   test/lab/lab.sh up [--with-opensearch]   start the 4 "VMs" (+ OpenSearch for Fluent Bit)
#   test/lab/lab.sh deploy [postgres|mysql|mssql] [ansible-playbook args]
#   test/lab/lab.sh healthcheck               Ansible health check (healthcheck.yml), same as on real VMs
#   test/lab/lab.sh verify                    extra checks run from this machine
#   test/lab/lab.sh api-test                  publish + call a test API (+ check OpenSearch)
#   test/lab/lab.sh ssh apim1                 shell on a "VM"
#   test/lab/lab.sh down                      stop and delete the containers (keeps the zip)
#
# Uses its own inventory and vars, so your real config is never touched.
set -euo pipefail
LAB="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$LAB/../.." && pwd)"
GEN="$LAB/.generated"
LOGS="$LAB/.logs"
APIM_VERSION=4.7.0
ZIP="$LAB/.cache/wso2am-$APIM_VERSION.zip"
# Random lab passwords, created once per machine in the git-ignored .generated/
lab_secrets="$GEN/lab-secrets.env"
if [[ ! -f $lab_secrets ]]; then
  mkdir -p "$GEN"
  rnd() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true; }
  # Lab- + random + -1: upper, lower, digit and symbol, as OpenSearch and SQL Server require
  (umask 077 && printf 'LAB_DB_PASSWORD=Lab-%s-1\nLAB_SA_PASSWORD=Lab-%s-1\nLAB_OS_PASSWORD=Lab-%s-1\n' \
    "$(rnd)" "$(rnd)" "$(rnd)" > "$lab_secrets")
fi
# shellcheck disable=SC1090
source "$lab_secrets"
export LAB_OS_PASSWORD   # read by compose.yml for the OpenSearch container
OS_PASSWORD=$LAB_OS_PASSWORD
# IPs inside the lab network; this machine uses the 127.0.0.1 ports instead
declare -A IP=([db]=172.30.0.10 [lb]=172.30.0.11 [apim1]=172.30.0.12 [apim2]=172.30.0.13 [opensearch]=172.30.0.20)
declare -A SSH_PORT=([db]=2210 [lb]=2211 [apim1]=2212 [apim2]=2213)
HTTPS_PORT=443   # lb publishes 443 on 127.0.0.1; *.localhost resolves here without /etc/hosts
SSH_OPTS=(-i "$LAB/.ssh/id_ed25519" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
# shellcheck source=../../scripts/ensure-ansible.sh
source "$REPO/scripts/ensure-ansible.sh"
compose() { docker compose -p apim-lab -f "$LAB/compose.yml" "$@"; }
on() { local h=$1; shift; ssh "${SSH_OPTS[@]}" -p "${SSH_PORT[$h]}" ubuntu@127.0.0.1 "$@"; }

up() {
  local profile=()
  [[ "${1:-}" == --with-opensearch ]] && profile=(--profile opensearch)
  mkdir -p "$LAB/.ssh" "$LAB/.cache"
  [[ -f "$LAB/.ssh/id_ed25519" ]] || ssh-keygen -q -t ed25519 -N '' -C apim-lab -f "$LAB/.ssh/id_ed25519"
  chmod 644 "$LAB/.ssh/id_ed25519.pub"   # read by sshd as the ubuntu user
  if [[ ! -f "$ZIP" ]]; then
    echo "==> Downloading WSO2 APIM $APIM_VERSION once (~540 MB), shared by both nodes"
    curl -fL -C - -o "$ZIP.part" "https://github.com/wso2/product-apim/releases/download/v$APIM_VERSION/wso2am-$APIM_VERSION.zip"
    mv "$ZIP.part" "$ZIP"
  fi
  echo "==> Starting lab containers"
  compose "${profile[@]}" up -d --build
  for h in db lb apim1 apim2; do
    printf '   waiting for SSH on %-5s ' "$h"
    for _ in $(seq 60); do on "$h" true 2>/dev/null && { echo ok; continue 2; }; sleep 2; done
    echo FAILED; exit 1
  done
}

deploy() {
  local db=${1:-postgres}; shift || true
  local fb=false
  compose ps --services --status running | grep -qx opensearch && fb=true
  mkdir -p "$GEN"
  cat > "$GEN/hosts.ini" <<INI
[db]
db1 ansible_host=127.0.0.1 ansible_port=${SSH_PORT[db]} private_ip=${IP[db]}
[lb]
lb1 ansible_host=127.0.0.1 ansible_port=${SSH_PORT[lb]} private_ip=${IP[lb]}
[apim]
apim1 ansible_host=127.0.0.1 ansible_port=${SSH_PORT[apim1]} private_ip=${IP[apim1]}
apim2 ansible_host=127.0.0.1 ansible_port=${SSH_PORT[apim2]} private_ip=${IP[apim2]}
[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=$LAB/.ssh/id_ed25519
ansible_ssh_common_args=-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
INI
  # Same keys configure.yml writes; passed with -e so they win over any real config
  cat > "$GEN/vars.yml" <<YML
db_type: $db
cp_domain: am.apim.localhost
gw_domain: api.apim.localhost
gateway_ip: ${IP[lb]}
ssl_mode: selfsigned
ssl_local_dir: $GEN/ssl
apim_encryption_key_file: $GEN/apim-encryption.key
db_password: $LAB_DB_PASSWORD
apim_admin_password: admin
mssql_pid: Developer
mssql_accept_eula: true
mssql_sa_password: $LAB_SA_PASSWORD
apim_env: lab
fluent_bit_install: $fb
opensearch_host: ${IP[opensearch]}
opensearch_password: $OS_PASSWORD
opensearch_tls_verify: false
# lab only: smaller heap, zip from the host cache instead of GitHub
apim_jvm_mem_opts: -Xms256m -Xmx1024m
apim_zip_url: file:///lab-cache/wso2am-$APIM_VERSION.zip
YML
  cd "$REPO"
  ensure_ansible
  ansible-playbook -i "$GEN/hosts.ini" -e "@$GEN/vars.yml" site.yml "$@"
}

check() {   # check "description" command...
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then echo "  PASS  $desc"; else echo "  FAIL  $desc"; fails=$((fails+1)); fi
}
via_lb()     { curl -sk --max-time 20 --resolve "$1:$HTTPS_PORT:127.0.0.1" "${@:3}" "https://$1:$HTTPS_PORT$2"; }
http_code()  { via_lb "$1" "$2" -o /dev/null -w '%{http_code}'; }
code_is()    { [[ $(http_code "$1" "$2") =~ $3 ]]; }
active()     { on "$1" sudo systemctl is-active --quiet "$2"; }
num_ge()     { local n; n=$("${@:2}" 2>/dev/null | tr -dc '0-9'); [[ -n $n && $n -ge $1 ]]; }
reach()      { on "$1" "timeout 5 bash -c '</dev/tcp/$2/$3'"; }
apim_log=/opt/wso2/wso2am-$APIM_VERSION/repository/logs/wso2carbon.log
err_count()  { on "$1" "sudo grep -c ' ERROR ' $apim_log || true"; }
table_count() {
  case $1 in
    postgres) on db "cd /tmp && sudo -u postgres psql -tAd wso2am_db -c \"select count(*) from information_schema.tables where table_schema='public'\"" ;;
    mysql)    on db "sudo mysql -NBe \"select count(*) from information_schema.tables where table_schema='WSO2AM_DB'\"" ;;
    mssql)    on db "SQLCMDPASSWORD=$LAB_SA_PASSWORD /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -h -1 -W -d WSO2AM_DB -Q 'set nocount on; select count(*) from sys.tables'" ;;
  esac
}

verify() {
  fails=0
  local db; db=$(awk '/^db_type:/{print $2}' "$GEN/vars.yml")
  echo "==> Services"
  check "wso2-apim running on apim1" active apim1 wso2-apim
  check "wso2-apim running on apim2" active apim2 wso2-apim
  check "nginx running on lb"        active lb nginx
  echo "==> Through Nginx (as a browser would)"
  check "https://am.apim.localhost/publisher answers"   code_is am.apim.localhost /publisher/ '^(200|302)$'
  check "https://am.apim.localhost/devportal answers"   code_is am.apim.localhost /devportal/ '^(200|302)$'
  check "Admin REST API logs in (DB works)"       bash -c "$(declare -f on via_lb); $(declare -p SSH_OPTS SSH_PORT HTTPS_PORT); via_lb am.apim.localhost /api/am/admin/v4/throttling/policies/application -u admin:admin -f | grep -q Unlimited"
  check "https://api.apim.localhost gateway answers"    code_is api.apim.localhost / '^[2-4][0-9][0-9]$'
  echo "==> Database ($db)"
  check "APIM tables imported (> 50)"             num_ge 50 table_count "$db"
  echo "==> Throttling sync between nodes"
  check "apim1 listens on 9611, 9711, 5672"       num_ge 3 on apim1 "ss -ltn | grep -cE ':(9611|9711|5672) '"
  check "apim2 listens on 9611, 9711, 5672"       num_ge 3 on apim2 "ss -ltn | grep -cE ':(9611|9711|5672) '"
  check "apim1 reaches apim2 on 9611/9711/5672"   bash -c "$(declare -f on reach); $(declare -p SSH_OPTS SSH_PORT); for p in 9611 9711 5672; do reach apim1 ${IP[apim2]} \$p || exit 1; done"
  check "apim2 reaches apim1 on 9611/9711/5672"   bash -c "$(declare -f on reach); $(declare -p SSH_OPTS SSH_PORT); for p in 9611 9711 5672; do reach apim2 ${IP[apim1]} \$p || exit 1; done"
  if grep -q '^fluent_bit_install: true' "$GEN/vars.yml"; then
    echo "==> Fluent Bit -> OpenSearch"
    check "fluent-bit running on apim1" active apim1 fluent-bit
    check "fluent-bit running on apim2" active apim2 fluent-bit
    echo "        (after an API call: test/lab/lab.sh ssh apim1, then"
    echo "         curl -sk -u admin:$OS_PASSWORD 'https://${IP[opensearch]}:9200/_cat/indices/apim_event_*?v')"
  fi
  echo "==> Logs (watching 60 s for new ERRORs; errors while the other node was still booting are normal)"
  # baseline taken after the port probes above, which make WSO2 log a TLS handshake error
  declare -A errs_before
  for h in apim1 apim2; do errs_before[$h]=$(err_count "$h" | tr -dc '0-9'); done
  sleep 60
  for h in apim1 apim2; do
    check "no new ERROR in $h wso2carbon.log" test "$(err_count "$h" | tr -dc '0-9')" = "${errs_before[$h]}"
  done
  echo; if [[ $fails -eq 0 ]]; then echo "All checks passed."; else echo "$fails check(s) failed."; return 1; fi
}

# The same Ansible health check you run against real VMs (healthcheck.yml)
healthcheck() {
  cd "$REPO"
  ensure_ansible
  ansible-playbook -i "$GEN/hosts.ini" -e "@$GEN/vars.yml" healthcheck.yml "$@"
}

# Publish a test API, call it through Nginx and (with OpenSearch) check analytics arrive
api_test() {
  fails=0
  local pub="/api/am/publisher/v4" id rev codes
  api() { via_lb am.apim.localhost "$pub$1" -u admin:admin -H 'Content-Type: application/json' "${@:2}"; }
  json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

  echo "==> Publishing test API 'LabEcho' (backend: Nginx on the lb VM)"
  id=$(api "/apis?query=name:LabEcho" | json "d['list'][0]['id'] if d.get('count') else ''")
  if [[ -z $id ]]; then
    id=$(api /apis -X POST -d '{
      "name": "LabEcho", "context": "/labecho", "version": "1.0.0", "policies": ["Unlimited"],
      "endpointConfig": {"endpoint_type": "http",
        "production_endpoints": {"url": "http://'"${IP[lb]}"'"},
        "sandbox_endpoints": {"url": "http://'"${IP[lb]}"'"}},
      "operations": [{"target": "/*", "verb": "GET", "authType": "None", "throttlingPolicy": "Unlimited"}]
    }' | json "d['id']")
    rev=$(api "/apis/$id/revisions" -X POST -d '{"description":"lab"}' | json "d['id']")
    api "/apis/$id/deploy-revision?revisionId=$rev" -X POST \
      -d '[{"name":"Default","vhost":"api.apim.localhost","displayOnDevportal":true}]' >/dev/null
    api "/apis/change-lifecycle?apiId=$id&action=Publish" -X POST >/dev/null
  fi
  check "API created and published" test -n "$id"

  echo "==> Calling https://api.apim.localhost/labecho/1.0.0/ 10 times through Nginx (round-robin to both nodes)"
  # The node that received the publish deploys first; the other gets it through
  # event sync a few seconds later, so retry until all 10 calls succeed.
  for _ in $(seq 12); do
    codes=$(for _ in $(seq 10); do http_code api.apim.localhost /labecho/1.0.0/; echo; done | sort | uniq -c | tr -s ' \n' ' ')
    [[ $codes != *404* ]] && break; sleep 5
  done
  echo "        status codes:$codes"
  # backend (Nginx :80) answers 301; a 404 means one gateway node never got the API
  check "both gateway nodes serve the API (no 404)" bash -c "[[ '$codes' != *404* && '$codes' == *301* ]]"

  if compose ps --services --status running | grep -qx opensearch; then
    echo "==> Waiting for analytics events in OpenSearch (env=lab)"
    local n=0
    for _ in $(seq 24); do
      n=$(on apim1 "curl -sk -u admin:$OS_PASSWORD 'https://${IP[opensearch]}:9200/apim_event_response-*/_count?q=env:lab'" 2>/dev/null \
          | python3 -c "import json,sys; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo 0)
      [[ $n -ge 10 ]] && break; sleep 5
    done
    echo "        events found: $n"
    check "API calls reached OpenSearch tagged env=lab" test "$n" -ge 10
    on apim1 "curl -sk -u admin:$OS_PASSWORD 'https://${IP[opensearch]}:9200/_cat/indices/apim_event_*?v'" | sed 's/^/        /'
  fi
  echo; if [[ $fails -eq 0 ]]; then echo "API test passed."; else echo "$fails check(s) failed."; return 1; fi
}

# Full cycle per run: fresh VMs -> deploy -> verify -> api-test -> deploy again (must change nothing)
run_one() {
  local run=$1 db=${1%+fb} log="$LOGS/$1.log" up_args=() result=PASS step
  [[ $run == *+fb ]] && up_args=(--with-opensearch)
  echo; echo "################ $run ################  (log: ${log#"$REPO"/})"
  {
    for step in down up deploy healthcheck verify api-test idempotency; do
      printf '  %-12s ' "$step" >&3
      case $step in
        down)        compose --profile opensearch down -v --remove-orphans ;;
        up)          up "${up_args[@]}" ;;
        deploy)      deploy "$db" ;;
        healthcheck) healthcheck ;;
        verify)      verify ;;
        api-test)    api_test ;;
        idempotency) deploy "$db" | tee "$LOGS/$run.redeploy.log"
                     # every host must report changed=0 and failed=0
                     ! grep -E '^[a-z0-9]+ +: ok=' "$LOGS/$run.redeploy.log" \
                       | grep -vqE 'changed=0 +unreachable=0 +failed=0 ' ;;
      esac && echo ok >&3 || { echo FAILED >&3; result=FAIL; break; }
    done
  } 3>&1 >"$log" 2>&1
  [[ $result == FAIL ]] && echo "  -> see $log; last lines:" && tail -15 "$log" | sed 's/^/     /'
  RESULTS+=("$run $result")
}

full_test() {
  local runs=("$@") start=$SECONDS r
  [[ ${#runs[@]} -eq 0 ]] && runs=(postgres+fb mysql mssql)
  for r in "${runs[@]}"; do
    [[ $r =~ ^(postgres|postgres\+fb|mysql|mssql)$ ]] || { echo "Unknown run '$r' (use postgres, postgres+fb, mysql, mssql)"; exit 1; }
  done
  command -v docker >/dev/null || { echo "Docker is required"; exit 1; }
  ensure_ansible || exit 1
  local free_mb; free_mb=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
  (( free_mb < 5000 )) && echo "WARNING: only ${free_mb} MB RAM free; the lab needs ~5 GB (~6 GB with SQL Server or OpenSearch)."
  mkdir -p "$LOGS"
  RESULTS=()
  echo "Runs: ${runs[*]}   (each ~15-20 min: fresh VMs, deploy, healthcheck, verify, api-test, redeploy)"
  for r in "${runs[@]}"; do run_one "$r"; done
  compose --profile opensearch down -v --remove-orphans >/dev/null 2>&1 || true
  echo; echo "================ SUMMARY ($(( (SECONDS-start)/60 )) min) ================"
  printf '  %s\n' "${RESULTS[@]}"
  echo "  (lab containers removed; logs in ${LOGS#"$REPO"/}/)"
  ! printf '%s\n' "${RESULTS[@]}" | grep -q FAIL
}

destroy() {
  compose --profile opensearch down -v --remove-orphans --rmi all 2>/dev/null || true
  # only the lab's own generated/downloaded files
  local d
  for d in .cache .generated .ssh .logs; do [[ -d "$LAB/$d" ]] && rm -rf -- "${LAB:?}/$d"; done
  echo "Lab destroyed: containers, network, images (apim-lab-vm, opensearch), APIM zip, keys, logs."
}

case "${1:-}" in
  up)     shift; up "$@" ;;
  deploy) shift; deploy "$@" ;;
  verify) verify ;;
  api-test) api_test ;;
  healthcheck) shift; healthcheck "$@" ;;
  ssh)    on "${2:?which host: db lb apim1 apim2}" ;;
  down)   compose --profile opensearch down -v --remove-orphans ;;
  test)   shift; full_test "$@" ;;
  destroy) destroy ;;
  *)      sed -n '2,19p' "$0"; exit 1 ;;
esac
