# WSO2 API Manager 4.7.0 HA on 4 VMs – Ansible

This playbook installs a highly available WSO2 API Manager 4.7.0 on 4 Ubuntu
VMs, from your own PC, with one command. It sets up:

- **2 APIM nodes** that share the load and keep throttling in sync
- **Nginx** in front of them, with HTTPS
- **A database** of your choice: PostgreSQL, MySQL or SQL Server
- **Optional:** Fluent Bit, sending API analytics to your OpenSearch

```
           Users / apps:  https://am.example.com   https://api.example.com
                                       |
                             +---------v---------+
                             |  VM2: Nginx (lb)  |  HTTPS (port 443)
                             +----+---------+----+
                         9443/8243|         |9443/8243
                  +---------------v-+     +-v---------------+
                  | VM3: APIM node1 |<--->| VM4: APIM node2 |  throttling sync
                  +--------+--------+     +--------+--------+  (9611/9711/5672)
                           +----------+-----------+
                                      |
                           +----------v----------+
                           |  VM1: Database (db) |  PostgreSQL | MySQL | SQL Server
                           +---------------------+
```

**Contents**

- [How to run it (step by step)](#how-to-run-it-step-by-step)
- [Everyday tasks](#everyday-tasks)
- [Troubleshooting](#troubleshooting)
- [Test without VMs (local lab)](#test-without-vms-local-lab)
- [Reference](#reference)

---

## How to run it (step by step)

In short:

```bash
git clone https://github.com/didee97/apim-vm-ansbile.git
cd apim-vm-ansbile
./deploy.sh
```

The steps below explain each part.

### Step 0 – What you need

**Your PC** (the machine you run Ansible from) needs Linux, or WSL on Windows,
with `git` and `python3`. You don't need to install Ansible: the scripts
install it into a `.venv/` folder inside this project the first time
(no sudo, and your system Python isn't touched).

**4 VMs.** Ubuntu 22.04 is recommended; it is what the test lab uses.
Ubuntu 24.04 is expected to work, except with SQL Server, which needs
20.04 or 22.04.

| VM | Role | UAT / test | Production |
|---|---|---|---|
| VM1 – db | Database | 2 vCPU, 4 GB RAM, 50 GB SSD (8 GB RAM for SQL Server) | 4 vCPU, 8–16 GB RAM, 100 GB+ SSD |
| VM2 – lb | Nginx | 2 vCPU, 2 GB RAM, 20 GB | 2 vCPU, 4 GB RAM, 30 GB |
| VM3 – apim1 | WSO2 APIM | 4 vCPU, 8 GB RAM, 50 GB SSD | 4–8 vCPU, 16 GB RAM, 100 GB SSD |
| VM4 – apim2 | WSO2 APIM | same as apim1 | same as apim1 |

**Network.** Open these ports:

| From → To | Ports |
|---|---|
| Your PC → all 4 VMs | 22 (SSH) |
| Users / apps → lb | 80, 443 |
| lb → apim1, apim2 | 9443, 8243 |
| apim1 ↔ apim2 (both ways) | 9611, 9711, 5672 |
| apim1, apim2 → db | 5432 (PostgreSQL) / 3306 (MySQL) / 1433 (SQL Server) |
| apim1, apim2 → OpenSearch | 9200 (only if you enable analytics) |

The VMs also need internet access during the deploy. They download Java,
APIM 4.7.0 (~540 MB, unless you use your own licensed zip) and the database
packages.

### Step 1 – Prepare the VMs

On every VM you need one user that can SSH in and use `sudo`. Use the same
user on all 4 VMs (for example `ubuntu`).

Choose how Ansible logs in:

- **SSH key (recommended: no passwords to type).** On your PC, create a key
  once if you don't have one:

  ```bash
  ssh-keygen -t ed25519
  ```

  Copy it to each VM (you type that VM's password one last time):

  ```bash
  ssh-copy-id ubuntu@10.0.0.10
  ```

  Repeat `ssh-copy-id` for all 4 VM IPs.

- **Password.** Install `sshpass` on your PC:

  ```bash
  sudo apt install sshpass
  ```

  `deploy.sh` then asks for the SSH and sudo passwords once per run. They
  are never saved.

Check that you can log in to every VM and use sudo (it may ask for the sudo
password):

```bash
ssh -t ubuntu@10.0.0.10 sudo -v
```

No error means that VM is ready. Repeat for all 4 VMs.

### Step 2 – Get the playbook

```bash
git clone https://github.com/didee97/apim-vm-ansbile.git
cd apim-vm-ansbile
```

Run every command below from this folder.

### Step 3 – Answer the questions

```bash
./configure.sh
```

You answer 8 short steps. Each step explains what it needs and gives an
example. Current values are shown in `[brackets]`; press Enter to keep them.
A wrong answer (bad IP, missing file, a key that doesn't match the
certificate…) is reported right away and asked again.

| Step | What it asks | Example |
|---|---|---|
| 1. Your 4 VMs | IP of the database VM, Nginx VM, APIM node 1 and APIM node 2 | `10.0.0.10` … |
| 2. SSH login | SSH user; SSH key or password; does sudo ask for a password | `ubuntu`, key `~/.ssh/id_ed25519` |
| 3. APIM package | **Open source** (each node downloads it from GitHub) or **licensed** (your WSO2 subscription zip). For licensed, give the zip file or the folder it is in, on your PC; it checks it is a WSO2 APIM 4.7.0 zip | `2`, `~/wso2/wso2am-4.7.0.zip` |
| 4. Database | PostgreSQL, MySQL 8 or SQL Server 2022; password for the `wso2carbon` DB user (Enter = generate one). SQL Server also asks the edition, licence acceptance and `sa` password | `1` |
| 5. Domain names | Control-plane domain (Publisher, DevPortal, Admin); gateway domain (API calls); the IP they point to, usually the Nginx VM | `am.example.com`, `api.example.com` |
| 6. SSL certificate | Create a self-signed one, or use your own certificate + key files (it checks that they match and cover both domains) | `1` |
| 7. WSO2 admin | Password for the `admin` user; environment name | `uat`, `prod` |
| 8. Analytics | Install Fluent Bit and send API analytics to OpenSearch? If yes: OpenSearch IP, port, user and password | `y`, `10.0.0.50` |

At the end you see all your answers:

```
  Save these settings? y = save, 1-8 = change that step, q = quit without saving [y]:
```

Your answers are saved in `inventory/hosts.ini`, `group_vars/all/10-config.yml`
and `group_vars/all/20-secrets.yml` (passwords, readable only by you). None
of these files go into git.

> If you skip this step, `./deploy.sh` runs `./configure.sh` for you the
> first time.

### Step 4 – (Optional) Dry run

```bash
./deploy.sh -- --check --diff
```

This shows what would change, without changing anything on the VMs. On
brand-new VMs it stops early with `DRY RUN STOPS HERE`, which is normal:
APIM has to be installed before its configuration can be previewed. A dry
run is most useful later, before you redeploy with changed settings.

### Step 5 – Deploy

```bash
./deploy.sh
```

What happens:

1. **Passwords:** if you chose password login, it asks once:
   ```
   SSH password for ubuntu on the VMs:
   sudo password [Enter = same as SSH password]:
   ```
2. **SSH check:** every VM must answer `ping: pong`.
3. **Deploy:** takes about **15–20 minutes**. The longest part is near the
   end:
   ```
   FAILED - RETRYING: [apim1]: apim_config : Wait for APIM to answer on 9443 (59 retries left).
   ```
   This is **normal**. Each APIM node needs 2–3 minutes to start, and node 2
   starts only after node 1 is up.
4. **Health check:** runs automatically at the end (see the next step).

A successful deploy ends with `failed=0` for every VM in the `PLAY RECAP`.

### Step 6 – Check that everything works

The health check runs automatically after every deploy. You can run it on its
own any time; it changes nothing:

```bash
./deploy.sh --healthcheck
```

It checks every VM and prints PASS / FAIL per check:

- **Database:** service running, reachable by the APIM nodes, WSO2 tables
  imported
- **APIM nodes:** service running and answering, gateway and throttling
  ports open, the nodes reach each other and the database, both nodes use
  the same encryption key, Fluent Bit running (if enabled)
- **Nginx:** config valid, both nodes reachable, Publisher / DevPortal /
  Admin API login work through it
- **Your PC:** the domains resolve, and Publisher and the gateway open

It ends with:

```
ALL CHECKS PASSED on db1, lb1, apim1, apim2, localhost
```

If something fails, the summary lists each failed check with a hint about
what to look at.

### Step 7 – Open it

**DNS.** Point both domains to the IP you gave in step 5 of the questions.
Ask your DNS admin, or for a quick test add this line to `/etc/hosts` on
your PC (`C:\Windows\System32\drivers\etc\hosts` on Windows):

```
10.0.0.11  am.example.com  api.example.com
```

**Open in your browser:**

| What | URL |
|---|---|
| Publisher (create and publish APIs) | `https://<control-plane domain>/publisher` |
| Developer Portal (subscribe, get keys) | `https://<control-plane domain>/devportal` |
| Admin portal | `https://<control-plane domain>/admin` |
| Carbon console | `https://<control-plane domain>/carbon` |
| Gateway (your apps call APIs here) | `https://<gateway domain>/<api-context>/<version>/` |

Log in as `admin` with the password from step 7 of the questions. If you
chose a self-signed certificate, the browser warns once. Click *Advanced →
Proceed*.

### Step 8 – (Optional) Analytics dashboards

If you enabled Fluent Bit, API calls appear in OpenSearch as
`apim_event_response-<date>` (successful calls) and `apim_event_faulty-<date>`
(failed or throttled calls), tagged with `env: <your environment>`. Make a
few API calls, then on the OpenSearch VM:

```bash
curl -sk -u admin:'<password>' 'https://localhost:9200/_cat/indices/apim_event_*?v'
```

Then import WSO2's `opensearchAnalyticsDashboards.ndjson` in OpenSearch
Dashboards (*Dashboards Management → Saved objects → Import*). Filter by
`env:uat` or `env:prod` to see one environment.

---

## Everyday tasks

| I want to… | Run |
|---|---|
| Change a setting (IP, domain, password, certificate…) and apply it | `./configure.sh`, then `./deploy.sh` |
| Change settings and deploy in one go | `./deploy.sh --reconfigure` |
| Switch from open source to your licensed zip, or install a newer licensed zip | `./configure.sh` (step 3), then `./deploy.sh` (see [Changing the APIM package](#changing-the-apim-package)) |
| See what a deploy would change, without changing anything | `./deploy.sh -- --check --diff` |
| Check that everything is healthy | `./deploy.sh --healthcheck` |
| Collect diagnostics when something is wrong (read-only) | `./deploy.sh --logs` |
| Only test SSH to all VMs | `./deploy.sh --check` |
| Re-apply only Nginx | `./deploy.sh -- --tags nginx` |
| Re-apply APIM config (restarts the nodes one by one) | `./deploy.sh -- --tags apim_config` |
| Start APIM nodes that were stopped | `./deploy.sh -- --tags apim_start` |
| Re-apply only Fluent Bit | `./deploy.sh -- --tags fluent_bit` |
| Give APIM more memory | Set `apim_jvm_mem_opts: "-Xms4g -Xmx8g"` in `group_vars/all/00-defaults.yml`, then `./deploy.sh -- --tags apim_config` |
| Encrypt the passwords file | `.venv/bin/ansible-vault encrypt group_vars/all/20-secrets.yml` (`deploy.sh` then asks for the vault password) |

Running `./deploy.sh` again is safe. It only changes what differs, and APIM
restarts only if its configuration changed.

### Changing the APIM package

Each APIM node remembers which zip it was installed from (a checksum in
`/opt/wso2/wso2am-4.7.0/.installed-from`). When `./deploy.sh` gets a
different zip, it reinstalls APIM on that node. That happens when you switch
open source → licensed, or licensed → open source, or give a newer licensed
zip with updates. It works on **one node at a time**, so the other node keeps
serving:

1. Stops APIM on the node.
2. Moves the old install aside as a backup:
   `/opt/wso2/wso2am-4.7.0-before-<date-time>`.
3. Unzips the new package, adds the JDBC driver, and re-applies your
   configuration (database, domains, certificate, throttling sync, shared
   encryption key).
4. Starts APIM and waits until it answers, then moves to the next node.

Your database, encryption key and settings stay the same, so APIs, users,
applications and subscriptions are kept. Once everything works, you can
delete the `-before-` backup folders to free about 1 GB per node. If a
licensed update needs database changes, WSO2 provides the scripts with the
update, and this playbook does not run them.


- `files/apim-encryption.key`: the encryption key both APIM nodes share. APIM
  encrypts secrets in the database with it. **If you lose it, that data can't
  be read.** It is created on the first deploy.
- `group_vars/all/20-secrets.yml`: the database, admin and OpenSearch
  passwords.
- `files/ssl/`: the self-signed certificate, if you chose one.

---

## Troubleshooting

| You see | What it means / what to do |
|---|---|
| `SSH password login needs 'sshpass'` | Run `sudo apt install sshpass`, or switch to SSH keys (Step 1). |
| `UNREACHABLE` / `Permission denied` | Wrong IP, user, password or key. Try `ssh <user>@<vm-ip>` by hand. Fix with `./configure.sh` (steps 1–2). |
| `Missing sudo password` / `sudo: a password is required` | Answer **y** to "Does sudo ask for a password?" in `./configure.sh` step 2. |
| `FAILED - RETRYING ... Wait for APIM to answer on 9443` | Normal while APIM starts (2–3 min per node). Only a problem if it runs out of retries; then check the APIM log (next row). |
| APIM doesn't start | On that node: `sudo journalctl -u wso2-apim -n 50` and `sudo tail -100 /opt/wso2/wso2am-4.7.0/repository/logs/wso2carbon.log` |
| `Cannot reach OpenSearch` | 401 = wrong OpenSearch password. Timeout = the OpenSearch VM's firewall doesn't allow the APIM nodes on port 9200. Certificate error = answer **n** to the certificate check in step 8. |
| Browser shows **502 Bad Gateway** | Nginx can't reach APIM: a node is down, or ports 9443/8243 are blocked. Run `./deploy.sh --healthcheck`. |
| Domain doesn't open in the browser | DNS isn't set up yet. Add the `/etc/hosts` line from Step 7. |
| Browser certificate warning | Expected with a self-signed certificate. Use your own certificate (questions, step 6) to avoid it. |
| `DRY RUN STOPS HERE` | Normal for a dry run on VMs where APIM isn't installed yet. |
| SQL Server: `needs Ubuntu 20.04/22.04` | SQL Server 2022 doesn't support Ubuntu 24.04. Use 22.04 for the database VM, or PostgreSQL / MySQL. |
| Strange Ansible errors after an upgrade | Delete `.venv/` and run again; it reinstalls a working Ansible. |

The health check (`./deploy.sh --healthcheck`) is the quickest way to find
which part is broken. To see why, run `./deploy.sh --logs`. It collects the
service state, memory, out-of-memory kills, open ports and the latest APIM
errors from every VM, without changing anything.

---

## Test without VMs (local lab)

You can try the whole deployment on your PC first. `test/lab/lab.sh` starts 4
Ubuntu 22.04 containers that act as the 4 VMs, and runs the same playbook
against them. It never touches your real settings. Step-by-step commands are
in **[TESTING.md](TESTING.md)**.

It needs Docker and about 5 GB of free RAM (more for SQL Server). In short:

```bash
test/lab/lab.sh up                  # start the 4 "VMs"
test/lab/lab.sh deploy postgres     # deploy (or: mysql, mssql)
test/lab/lab.sh healthcheck         # same health check as on real VMs
test/lab/lab.sh down                # remove the containers
```

Or test everything (PostgreSQL + Fluent Bit, MySQL, SQL Server) in one
command, about an hour:

```bash
test/lab/lab.sh test
```

While the lab runs, open `https://am.apim.localhost/publisher` in your
browser (admin / admin). To remove the lab completely (containers, images,
downloads):

```bash
test/lab/lab.sh destroy
```

---

## Reference

### What gets deployed

| Step (tag) | VMs | What it does |
|---|---|---|
| `preflight`, `ssl` | your PC | Checks the settings; creates the shared encryption key and the self-signed certificate, or checks your certificate |
| – | all | Base packages; on the APIM nodes, `/etc/hosts` points both domains to the gateway IP |
| `apim_install` | apim | Java 21, a `wso2` service user, APIM 4.7.0 in `/opt/wso2` (downloaded, or your licensed zip copied from your PC), the JDBC driver for your database |
| `db` | db | Installs the database, opens it to the APIM nodes, creates the APIM and shared databases and the `wso2carbon` user, imports the WSO2 SQL scripts (only into empty databases) |
| `nginx` | lb | HTTPS for both domains, load-balancing to both nodes (sticky sessions for the portals) |
| `apim_config` | apim | `deployment.toml` (database, domains, throttling sync, analytics, shared encryption key), trusts the Nginx certificate, systemd service, starts node 1 and then node 2 |
| `fluent_bit` | apim | Optional: installs Fluent Bit, checks it can log in to OpenSearch, sends `apim_metrics.log` to OpenSearch |

### SQL scripts

They come from `dbscripts/` inside the APIM zip, so they always match the
installed version:

| Database | Shared DB | APIM DB |
|---|---|---|
| PostgreSQL | `dbscripts/postgresql.sql` | `dbscripts/apimgt/postgresql.sql` |
| MySQL | `dbscripts/mysql.sql` | `dbscripts/apimgt/mysql.sql` |
| SQL Server | `dbscripts/mssql.sql` | `dbscripts/apimgt/mssql.sql` |

### Throttling sync between the nodes

Each node uses both Traffic Managers and forwards throttle events to the other
node:

```toml
[apim.throttling]
event_duplicate_url = ["tcp://<other node>:5672"]

[[apim.throttling.url_group]]
traffic_manager_urls = ["tcp://<node1>:9611"]
traffic_manager_auth_urls = ["ssl://<node1>:9711"]
type = "loadbalance"

[[apim.throttling.url_group]]
traffic_manager_urls = ["tcp://<node2>:9611"]
traffic_manager_auth_urls = ["ssl://<node2>:9711"]
type = "loadbalance"
```

### Analytics (Fluent Bit → OpenSearch)

This follows Part 3 of the OpenSearch & Fluent Bit guide. OpenSearch itself is
not installed by this playbook: it is the shared logging VM for UAT and
production.

- **APIM side:** `deployment.toml` gets `[apim.analytics] enable = true` and
  `type = "opensearch"`, so every API call is written to
  `repository/logs/apim_metrics.log`.
- **Fluent Bit** (official apt repo) sends successful calls to
  `apim_event_response-<date>` and failed or throttled calls to
  `apim_event_faulty-<date>`, tagged with `env: <environment>`.
- **Password file:** `/etc/fluent-bit/fluent-bit.conf` holds the OpenSearch
  password, so only root can read it.

### Different SSH address and internal IP

If you SSH to a VM on a different address than the one the other VMs use (NAT,
bastion, public IP), set `private_ip` for that host in `inventory/hosts.ini`:

```ini
apim1 ansible_host=203.0.113.12 private_ip=10.0.0.12
```

`private_ip` is used for the Nginx upstreams, throttling sync and database
access. If it isn't set, it is the same as `ansible_host`.

### Project layout

| Path | What it is |
|---|---|
| `deploy.sh` | Runs everything: installs Ansible, asks the questions (first time), deploys, health check |
| `configure.sh` | The step-by-step questions |
| `site.yml` | The main playbook |
| `healthcheck.yml` | The health-check playbook |
| `configure.yml` | Saves the answers from `configure.sh` (don't run it directly) |
| `roles/` | `common`, `apim_install`, `db`, `nginx`, `apim_config`, `fluent_bit` |
| `group_vars/all/00-defaults.yml` | Advanced settings: APIM version, Java, memory, driver versions, DB names |
| `inventory/hosts.ini`, `group_vars/all/10-config.yml`, `20-secrets.yml` | Your answers (created by `configure.sh`, not in git) |
| `files/` | Encryption key and self-signed certificate (created on first deploy, not in git) |
| `test/lab/` | The local test lab |
| `TESTING.md` | Step-by-step lab commands |
