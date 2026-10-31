# Testing step by step

Run every command from the project folder:

```bash
cd ~/apim-vm-ansbile
```

You don't need to install Ansible. The scripts install it into `.venv/` on
first use.

Only one lab command can run at a time. Two runs at once break each other,
because they share the same containers.

---

## A. Test on this PC (no VMs needed)

### 1. Start the 4 "VMs"

```bash
test/lab/lab.sh up
```

This starts 4 Ubuntu 22.04 containers: db, lb (Nginx), apim1 and apim2. The
first time, it downloads the APIM zip (about 540 MB).

### 2. Deploy with the Ansible playbook

```bash
test/lab/lab.sh deploy postgres
```

Use `mysql` or `mssql` instead of `postgres` for the other databases. This
takes about 10–15 minutes. At the end, every host must show `failed=0` in
the `PLAY RECAP`.

### 3. Check every service with the Ansible health check

```bash
test/lab/lab.sh healthcheck
```

This runs `healthcheck.yml`, the same playbook you use on real VMs. You see
`PASS` / `FAIL` per check for each VM, and it ends with:

```
ALL CHECKS PASSED on db1, lb1, apim1, apim2, localhost
```

If anything fails, the summary lists each failed check and what to look at.

### 4. Call the services from this PC

Names ending in `.localhost` always point to your own PC, so you don't need
to edit `/etc/hosts`.

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://am.apim.localhost/publisher/
```
```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://am.apim.localhost/devportal/apis
```
```bash
curl -sk -u admin:admin https://am.apim.localhost/api/am/admin/v4/throttling/policies/application
```

The first two print `200`. The last one returns JSON, which proves APIM can
use its database.

In your browser, the certificate is self-signed, so click *Advanced →
Proceed*. Log in as admin / admin:

| What | URL |
|---|---|
| Publisher | https://am.apim.localhost/publisher |
| Developer Portal | https://am.apim.localhost/devportal |
| Admin portal | https://am.apim.localhost/admin |
| Carbon console | https://am.apim.localhost/carbon |
| Gateway (API calls) | https://api.apim.localhost/&lt;context&gt;/&lt;version&gt;/ |

### 5. Publish an API and call it through the gateway

```bash
test/lab/lab.sh api-test
```

This creates the API `LabEcho` and calls it 10 times through Nginx. Both APIM
nodes must answer. You can then call it yourself:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://api.apim.localhost/labecho/1.0.0/
```

It prints `301`, which is the backend's own answer passed through the gateway.

### 6. (Optional) Break something and see the health check catch it

```bash
test/lab/lab.sh ssh apim2
```
```bash
sudo systemctl stop wso2-apim
```
```bash
exit
```
```bash
test/lab/lab.sh healthcheck
```

The summary now lists the apim2 failures and the run exits with an error.
The Publisher and gateway checks still pass, because Nginx sends traffic to
apim1. Bring apim2 back with the playbook:

```bash
test/lab/lab.sh deploy postgres --tags apim_start
```
```bash
test/lab/lab.sh healthcheck
```

### 7. Test Fluent Bit → OpenSearch (optional)

```bash
test/lab/lab.sh down
```
```bash
test/lab/lab.sh up --with-opensearch
```
```bash
test/lab/lab.sh deploy postgres
```
```bash
test/lab/lab.sh healthcheck
```
```bash
test/lab/lab.sh api-test
```

`api-test` now also shows the `apim_event_response-<date>` index in
OpenSearch, with the events tagged `env=lab`.

### 8. Stop or remove the lab

```bash
test/lab/lab.sh down
```

`down` removes the containers and keeps the zip for next time. To remove
everything (containers, images, zip, keys and logs):

```bash
test/lab/lab.sh destroy
```

### Everything in one command

```bash
test/lab/lab.sh test
```

This runs all of the above for PostgreSQL with Fluent Bit, then MySQL, then
SQL Server, in about an hour. It prints a PASS/FAIL summary and keeps logs in
`test/lab/.logs/`.

---

## B. Check your real VMs

After `./deploy.sh` (which runs the health check automatically at the end),
you can re-check any time:

```bash
./deploy.sh --healthcheck
```

Or call the playbook directly:

```bash
.venv/bin/ansible-playbook healthcheck.yml
```

The checks are the same as in the lab. The last part, "from this machine",
needs your PC to resolve the domains. Add DNS records, or add this line to
`/etc/hosts`:

```
<gateway_ip>  <cp_domain>  <gw_domain>
```
