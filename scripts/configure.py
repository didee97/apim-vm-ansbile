"""Step-by-step questions for the WSO2 APIM deployment.

Run through ./configure.sh (or ./deploy.sh --reconfigure). Asks clear,
validated questions, shows a review screen, then hands the answers to
configure.yml, which writes inventory/hosts.ini and group_vars/all/*.yml.
Current values are shown in [brackets]; press Enter to keep them.
"""
import datetime
import getpass
import ipaddress
import json
import os
import re
import secrets
import string
import sys

import yaml

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TTY = sys.stdout.isatty()
BOLD, DIM, GREEN, RED, YELLOW, RESET = (
    ("\033[1m", "\033[2m", "\033[32m", "\033[31m", "\033[33m", "\033[0m") if TTY else ("",) * 6)
STEPS = 7
DOMAIN_RE = re.compile(r"^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$")


# ---------------------------------------------------------------- helpers
def header(n, title, intro):
    print(f"\n{BOLD}━━━ Step {n} of {STEPS}: {title} ━━━{RESET}")
    for line in intro.strip().splitlines():
        print(f"{DIM}  {line}{RESET}")
    print()


def error(msg):
    print(f"    {RED}✗ {msg}{RESET}")


def ask(question, current="", example="", check=None, allow_empty=False):
    """Ask until the answer passes check(answer) -> error message or None."""
    hint = f" {DIM}(e.g. {example}){RESET}" if example and not current else ""
    default = f" [{current}]" if current != "" else ""
    while True:
        answer = input(f"  {question}{hint}{default}: ").strip() or str(current)
        if not answer and not allow_empty:
            error("This is required.")
            continue
        problem = check(answer) if check else None
        if problem:
            error(problem)
            continue
        return answer


def choose(question, options, current):
    """options: list of (value, label). Accepts the number or the value."""
    print(f"  {question}")
    for i, (value, label) in enumerate(options, 1):
        mark = f"{GREEN}  ← current{RESET}" if value == current else ""
        print(f"    {i}) {label}{mark}")
    values = [v for v, _ in options]
    current_no = values.index(current) + 1 if current in values else 1
    while True:
        answer = input(f"  Choose 1-{len(options)} [{current_no}]: ").strip() or str(current_no)
        if answer.isdigit() and 1 <= int(answer) <= len(options):
            return values[int(answer) - 1]
        if answer in values:
            return answer
        error(f"Type a number from 1 to {len(options)}.")


def yes_no(question, current):
    default = "y" if current else "n"
    while True:
        answer = (input(f"  {question} (y/n) [{default}]: ").strip().lower() or default)
        if answer in ("y", "yes"):
            return True
        if answer in ("n", "no"):
            return False
        error("Type y or n.")


def secret(question, has_current, generate=None, check=None, confirm=True, keep_label="keep current"):
    """Hidden input. Enter keeps the current value (or generates one)."""
    if has_current:
        enter = f"Enter = {keep_label}"
    elif generate:
        enter = "Enter = generate a strong one"
    else:
        enter = ""
    while True:
        value = getpass.getpass(f"  {question}{f' ({enter})' if enter else ''}: ")
        if not value:
            if has_current:
                return None  # keep
            if generate:
                return generate()
            error("This is required.")
            continue
        problem = check(value) if check else None
        if problem:
            error(problem)
            continue
        if confirm and getpass.getpass("  Type it again to confirm: ") != value:
            error("The two entries don't match. Try again.")
            continue
        return value


def random_password(prefix=""):
    alphabet = string.ascii_letters + string.digits
    return prefix + "".join(secrets.choice(alphabet) for _ in range(20))


def check_ip(value):
    try:
        ipaddress.IPv4Address(value)
    except ValueError:
        return "Not a valid IPv4 address (example: 10.0.0.10)."
    return None


def check_domain(value):
    if not DOMAIN_RE.match(value):
        return "Not a valid domain name (example: am.example.com)."
    return None


def check_path(value):
    if not os.path.isfile(os.path.expanduser(value)):
        return f"File not found on this machine: {value}"
    return None


# ---------------------------------------------------------------- current values
def load_yaml(path):
    try:
        with open(path) as f:
            text = f.read()
    except FileNotFoundError:
        return {}, False
    if text.startswith("$ANSIBLE_VAULT"):
        return {}, True
    return yaml.safe_load(text) or {}, False


def load_inventory():
    hosts, all_vars, group = {}, {}, None
    try:
        with open(os.path.join(REPO, "inventory/hosts.ini")) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("["):
                    group = line.strip("[]")
                    continue
                if group == "all:vars" and "=" in line:
                    k, v = line.split("=", 1)
                    all_vars[k.strip()] = v.strip()
                elif group:
                    parts = line.split()
                    kv = dict(p.split("=", 1) for p in parts[1:] if "=" in p)
                    hosts.setdefault(group, []).append(kv.get("ansible_host", parts[0]))
    except FileNotFoundError:
        pass
    return hosts, all_vars


# ---------------------------------------------------------------- certificate check
def check_certificate(cert_path, key_path, domains):
    """Returns a list of problems (empty = fine). Uses the cryptography package."""
    try:
        from cryptography import x509
        from cryptography.hazmat.primitives import serialization
    except ImportError:
        return []  # site.yml checks it again before deploying
    problems = []
    try:
        with open(os.path.expanduser(cert_path), "rb") as f:
            cert = x509.load_pem_x509_certificates(f.read())[0]
    except Exception as e:  # noqa: BLE001
        return [f"Can't read the certificate as PEM: {e}"]
    try:
        with open(os.path.expanduser(key_path), "rb") as f:
            key = serialization.load_pem_private_key(f.read(), password=None)
    except TypeError:
        return ["The private key has a password. Use an unencrypted key (openssl pkey -in key -out key.nopass)."]
    except Exception as e:  # noqa: BLE001
        return [f"Can't read the private key as PEM: {e}"]
    pub = serialization.PublicFormat.SubjectPublicKeyInfo
    enc = serialization.Encoding.PEM
    if cert.public_key().public_bytes(enc, pub) != key.public_key().public_bytes(enc, pub):
        problems.append("The key does not belong to this certificate.")
    if cert.not_valid_after_utc < datetime.datetime.now(datetime.timezone.utc):
        problems.append(f"The certificate expired on {cert.not_valid_after_utc:%Y-%m-%d}.")
    try:
        sans = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value.get_values_for_type(x509.DNSName)
    except x509.ExtensionNotFound:
        sans = []
    for d in domains:
        if d not in sans and f"*.{d.split('.', 1)[1]}" not in sans:
            problems.append(f"The certificate does not cover {d} (it covers: {', '.join(sans) or 'nothing'}).")
    return problems


# ---------------------------------------------------------------- the steps
def step_vms(a):
    header(1, "Your 4 VMs", """
The deployment uses 4 Ubuntu VMs. Give the IP address Ansible should SSH to.
  • Database VM      – PostgreSQL, MySQL or SQL Server
  • Load balancer VM – Nginx; users and apps connect here (HTTPS)
  • APIM node 1 + 2  – WSO2 API Manager, both run everything and share the load""")
    a["db_ip"] = ask("Database VM IP", a.get("db_ip", ""), "10.0.0.10", check_ip)
    a["lb_ip"] = ask("Load balancer (Nginx) VM IP", a.get("lb_ip", ""), "10.0.0.11", check_ip)
    a["node1_ip"] = ask("APIM node 1 IP", a.get("node1_ip", ""), "10.0.0.12", check_ip)

    def not_node1(v):
        return check_ip(v) or ("Node 2 must be a different VM than node 1." if v == a["node1_ip"] else None)
    a["node2_ip"] = ask("APIM node 2 IP", a.get("node2_ip", ""), "10.0.0.13", not_node1)


def step_ssh(a):
    header(2, "How Ansible logs in to the VMs", """
Ansible connects to every VM over SSH with one user that can use sudo.
An SSH key is easiest (no passwords to type). To set one up: ssh-copy-id <user>@<vm-ip>""")
    a["ssh_user"] = ask("SSH user on the VMs", a.get("ssh_user", ""), "ubuntu")
    method = choose("How should Ansible log in?", [
        ("key", "With my SSH key (recommended)"),
        ("password", "With a password (you type it when deploying; it is never saved)"),
    ], a.get("login_method", "key"))
    if method == "key":
        default_key = a.get("ssh_key") or next(
            (p for p in ("~/.ssh/id_ed25519", "~/.ssh/id_rsa") if os.path.isfile(os.path.expanduser(p))), "")
        a["ssh_key"] = ask("Path to your SSH private key", default_key, "~/.ssh/id_ed25519", check_path)
    else:
        a["ssh_key"] = ""
        if not any(os.access(os.path.join(p, "sshpass"), os.X_OK) for p in os.environ.get("PATH", "").split(":")):
            print(f"    {YELLOW}! Password login needs 'sshpass' on this PC: sudo apt install sshpass{RESET}")
    a["sudo_ask"] = "y" if yes_no("Does sudo ask for a password on the VMs?", a.get("sudo_ask", "y") == "y") else "n"


def step_database(a, s):
    header(3, "Database", """
Which database should be installed on the database VM? The WSO2 tables are
created from the SQL scripts that ship with APIM 4.7.0.""")
    a["db_type"] = choose("Database:", [
        ("postgres", "PostgreSQL"),
        ("mysql", "MySQL 8"),
        ("mssql", "Microsoft SQL Server 2022 (needs Ubuntu 22.04 and 2 GB+ RAM on the DB VM)"),
    ], a.get("db_type", "postgres"))
    pw = secret("Password for the database user 'wso2carbon'", "db_password" in s,
                generate=random_password)
    if pw is not None:
        s["db_password"] = pw
    if a["db_type"] == "mssql":
        print()
        a["mssql_pid"] = choose("SQL Server edition:", [
            ("Developer", "Developer – free, for test/UAT only (NOT licensed for production)"),
            ("Express", "Express – free, max 10 GB per database"),
            ("Standard", "Standard – needs a licence"),
            ("Enterprise", "Enterprise – needs a licence"),
        ], a.get("mssql_pid", "Developer"))
        print(f"  {DIM}Licence terms: https://go.microsoft.com/fwlink/?LinkId=746388{RESET}")
        while not yes_no("Do you accept the Microsoft SQL Server licence terms?", a.get("mssql_accept_eula", False)):
            error("SQL Server can't be installed without accepting them. Answer y, or go back and pick another database.")
            if yes_no("Pick another database instead?", True):
                return step_database(a, s)
        a["mssql_accept_eula"] = True

        def sa_rules(v):
            groups = sum(bool(re.search(p, v)) for p in (r"[a-z]", r"[A-Z]", r"[0-9]", r"[^a-zA-Z0-9]"))
            return None if len(v) >= 8 and groups >= 3 else \
                "Needs 8+ characters and 3 of: lower case, upper case, digit, symbol."
        pw = secret("Password for the SQL Server 'sa' admin", "mssql_sa_password" in s,
                    generate=lambda: random_password("Sa1"), check=sa_rules)
        if pw is not None:
            s["mssql_sa_password"] = pw
    return None


def step_domains(a):
    header(4, "Domain names", """
Two names, both pointing to the load balancer:
  • Control-plane domain – people open Publisher, Developer Portal and Admin here
  • Gateway domain       – applications call your APIs here""")
    a["cp_domain"] = ask("Control-plane domain", a.get("cp_domain", ""), "am.example.com", check_domain)

    def other(v):
        return check_domain(v) or ("Use a different name than the control-plane domain." if v == a["cp_domain"] else None)
    a["gw_domain"] = ask("Gateway domain", a.get("gw_domain", ""), "api.example.com", other)
    print(f"\n  {DIM}Which IP do these names point to (DNS)? Normally the load balancer VM;")
    print(f"  use a virtual IP if you put another load balancer in front.{RESET}")
    a["gateway_ip"] = ask("IP the domains point to", a.get("gateway_ip") or a["lb_ip"], "", check_ip)


def step_ssl(a):
    header(5, "SSL certificate", f"""
HTTPS certificate for {a['cp_domain']} and {a['gw_domain']} on the load balancer.""")
    a["ssl_mode"] = choose("Certificate:", [
        ("selfsigned", "Create a self-signed certificate (fine for testing; browsers show a warning)"),
        ("existing", "Use my own certificate files (from your CA or Let's Encrypt)"),
    ], a.get("ssl_mode", "selfsigned"))
    if a["ssl_mode"] == "selfsigned":
        return
    print(f"  {DIM}Files on this PC, in PEM format. The certificate file should contain the server")
    print(f"  certificate first, then any intermediate certificates. The key must have no password.{RESET}")
    while True:
        a["ssl_cert_src"] = os.path.expanduser(ask("Certificate file", a.get("ssl_cert_src", ""), "~/certs/fullchain.crt", check_path))
        a["ssl_key_src"] = os.path.expanduser(ask("Private key file", a.get("ssl_key_src", ""), "~/certs/private.key", check_path))
        problems = check_certificate(a["ssl_cert_src"], a["ssl_key_src"], [a["cp_domain"], a["gw_domain"]])
        if not problems:
            print(f"    {GREEN}✓ Certificate and key match and cover both domains.{RESET}")
            return
        for p in problems:
            error(p)
        a.pop("ssl_cert_src", None), a.pop("ssl_key_src", None)
        print("  Let's try other files.")


def step_wso2(a, s):
    header(6, "WSO2 admin and environment", """
The WSO2 super-admin logs in to Publisher, Developer Portal, Admin and Carbon.
The environment name tags this deployment's analytics (e.g. uat, prod).""")

    def strong(v):
        return "Use at least 8 characters." if len(v) < 8 else None
    s.setdefault("apim_admin_password", "admin")
    pw = secret("Password for the WSO2 'admin' user", True, check=strong,
                keep_label="keep 'admin'" if s["apim_admin_password"] == "admin" else "keep current")
    if pw is not None:
        s["apim_admin_password"] = pw
    if s.get("apim_admin_password") == "admin":
        print(f"    {YELLOW}! The admin password is 'admin'. Change it before production.{RESET}")

    def env_name(v):
        return None if re.match(r"^[a-z0-9][a-z0-9_-]*$", v) else "Use lower-case letters, digits, - or _ (e.g. uat, prod)."
    a["apim_env"] = ask("Environment name", a.get("apim_env", "uat"), "", env_name).lower()


def step_analytics(a, s):
    header(7, "API analytics (optional)", """
Fluent Bit can send every API call (success, errors, latency) from both APIM nodes
to an OpenSearch server you already have, for the WSO2 analytics dashboards.""")
    a["fluent_bit_install"] = yes_no("Install Fluent Bit and send analytics to OpenSearch?",
                                     bool(a.get("fluent_bit_install", False)))
    if not a["fluent_bit_install"]:
        return

    def host(v):
        return None if not check_ip(v) or not check_domain(v) else "Give an IP address or a domain name."

    def port(v):
        return None if v.isdigit() and 1 <= int(v) <= 65535 else "Give a port number (OpenSearch uses 9200)."
    a["opensearch_host"] = ask("OpenSearch IP or domain", a.get("opensearch_host", ""), "10.0.0.50", host)
    a["opensearch_port"] = int(ask("OpenSearch port", str(a.get("opensearch_port", 9200)), "", port))
    a["opensearch_user"] = ask("OpenSearch user", a.get("opensearch_user", "admin"))
    pw = secret(f"OpenSearch password for '{a['opensearch_user']}'", "opensearch_password" in s, confirm=False)
    if pw is not None:
        s["opensearch_password"] = pw
    a["opensearch_tls_verify"] = yes_no(
        "Check OpenSearch's HTTPS certificate? (say n while it still uses the demo certificates)",
        bool(a.get("opensearch_tls_verify", False)))


# ---------------------------------------------------------------- review
def review(a, s):
    def pw(k):
        return f"{GREEN}set{RESET}" if s.get(k) else f"{RED}missing{RESET}"
    db_names = {"postgres": "PostgreSQL", "mysql": "MySQL 8", "mssql": "SQL Server 2022"}
    print(f"\n{BOLD}━━━ Review ━━━{RESET}")
    rows = [
        ("1", "Database VM", a["db_ip"]),
        ("", "Load balancer VM", a["lb_ip"]),
        ("", "APIM nodes", f"{a['node1_ip']}, {a['node2_ip']}"),
        ("2", "SSH login", f"{a['ssh_user']} with " + (f"key {a['ssh_key']}" if a["ssh_key"] else "password (asked when deploying)")
         + (", sudo asks a password" if a["sudo_ask"] == "y" else "")),
        ("3", "Database", db_names[a["db_type"]] + (f" {a['mssql_pid']} edition" if a["db_type"] == "mssql" else "")
         + f", wso2carbon password {pw('db_password')}"),
        ("4", "Control plane", f"https://{a['cp_domain']}/publisher, /devportal, /admin"),
        ("", "Gateway", f"https://{a['gw_domain']}"),
        ("", "Domains point to", a["gateway_ip"]),
        ("5", "SSL", "self-signed" if a["ssl_mode"] == "selfsigned" else f"{a['ssl_cert_src']} + {a['ssl_key_src']}"),
        ("6", "WSO2 admin", f"admin, password {pw('apim_admin_password')}"),
        ("", "Environment", a["apim_env"]),
        ("7", "Analytics", (f"Fluent Bit → https://{a['opensearch_host']}:{a['opensearch_port']} as {a['opensearch_user']}, "
                            f"password {pw('opensearch_password')}") if a["fluent_bit_install"] else "off"),
    ]
    for step, label, value in rows:
        print(f"  {DIM}{step:>1}{RESET} {label:<17} {value}")
    print()
    while True:
        answer = input(f"  Save these settings? {BOLD}y{RESET} = save, 1-7 = change that step, q = quit without saving [y]: ").strip().lower() or "y"
        if answer in ("y", "yes", "q") or (answer.isdigit() and 1 <= int(answer) <= STEPS):
            return answer
        error("Type y, a step number 1-7, or q.")


# ---------------------------------------------------------------- main
def main():
    out_path = sys.argv[1]
    config, _ = load_yaml(os.path.join(REPO, "group_vars/all/10-config.yml"))
    current_secrets, vaulted = load_yaml(os.path.join(REPO, "group_vars/all/20-secrets.yml"))
    hosts, inv_vars = load_inventory()

    a = {k: v for k, v in config.items()}
    for key, group, i in (("db_ip", "db", 0), ("lb_ip", "lb", 0), ("node1_ip", "apim", 0), ("node2_ip", "apim", 1)):
        if len(hosts.get(group, [])) > i:
            a[key] = hosts[group][i]
    if "ansible_user" in inv_vars:
        a["ssh_user"] = inv_vars["ansible_user"]
    a["ssh_key"] = inv_vars.get("ansible_ssh_private_key_file", "")
    if inv_vars:  # existing inventory: keep its login method
        a["login_method"] = "key" if a["ssh_key"] else "password"
    s = {k: v for k, v in current_secrets.items() if v not in (None, "")}

    print(f"{BOLD}WSO2 API Manager 4.7.0 – deployment settings{RESET}")
    print(f"{DIM}7 short steps. Current values are in [brackets]: press Enter to keep them. Ctrl+C quits without saving.{RESET}")
    if vaulted:
        print(f"{YELLOW}! group_vars/all/20-secrets.yml is vault-encrypted, so passwords will be asked again and saved unencrypted;")
        print(f"  re-encrypt afterwards with: ansible-vault encrypt group_vars/all/20-secrets.yml{RESET}")

    steps = {1: lambda: step_vms(a), 2: lambda: step_ssh(a), 3: lambda: step_database(a, s),
             4: lambda: step_domains(a), 5: lambda: step_ssl(a), 6: lambda: step_wso2(a, s),
             7: lambda: step_analytics(a, s)}
    for n in range(1, STEPS + 1):
        steps[n]()
    while True:
        choice = review(a, s)
        if choice == "q":
            print("Nothing saved.")
            return 1
        if choice in ("y", "yes"):
            break
        steps[int(choice)]()

    a.pop("login_method", None)
    a.setdefault("mssql_pid", "Developer")
    a.setdefault("mssql_accept_eula", False)
    with open(out_path, "w") as f:
        json.dump({"answers": a, "answer_secrets": s}, f)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyboardInterrupt, EOFError):
        print("\nStopped. Nothing saved.")
        sys.exit(1)
