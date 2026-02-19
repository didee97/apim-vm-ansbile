# WSO2 API Manager HA Deployment – Ansible Playbook

This Ansible playbook automates the deployment of a high-availability **WSO2 API Manager 4.6.0** environment with:

- MySQL database server  
- Nginx load balancer with SSL  
- Two WSO2 APIM nodes  
- Systemd service configuration  
- Automated database initialization  

The setup provisions a production-style architecture with remote database access, SSL termination, and load-balanced API Manager nodes.

---

# Architecture Overview

The playbook configures three main components:

## 1. MySQL Server

- Installs MySQL and required Python dependencies  
- Creates:
  - APIM database  
  - Shared database  
- Imports required SQL scripts  
- Creates DB user and grants privileges  
- Enables remote access (`bind-address = 0.0.0.0`)  

## 2. Nginx Load Balancer

- Installs Nginx  
- Generates a self-signed SSL certificate  
- Deploys:
  - Upstream load balancer configuration  
  - WSO2 server block configuration  
- Removes default site  
- Updates `/etc/hosts`  
- Restarts Nginx  

## 3. WSO2 API Manager Nodes

- Installs Java 11 and unzip  
- Downloads and extracts WSO2 APIM 4.6.0  
- Downloads MySQL JDBC driver  
- Configures node-specific `deployment.toml`  
- Creates systemd service  
- Enables and starts APIM service  
- Updates `/etc/hosts`  

---

# Inventory Structure

Example inventory file:

```ini
[mysql]
mysql-server-ip

[nginx]
nginx-server-ip

[apim]
apim-node1-ip
apim-node2-ip
```

---

# Required Variables (vars.yml)

Create a `vars.yml` file containing:

```yaml
# Domain
domain_name: "example.com"

# SSL
ssl_dir: "/etc/nginx/ssl"

# MySQL
apim_db_user: "wso2carbon"
apim_db_password: "wso2carbon"
apim_db: "WSO2AM_DB"
apim_shared_db: "WSO2AM_SHARED_DB"
sql_dir: "/home/{{ ansible_user }}/sql"

mysql_apim_sql_url: "https://raw.githubusercontent.com/wso2/docker-apim/master/docker-compose/apim-with-analytics/conf/mysql/scripts/mysql_apim.sql"
mysql_shared_sql_url: "https://raw.githubusercontent.com/wso2/docker-apim/master/docker-compose/apim-with-analytics/conf/mysql/scripts/mysql_shared.sql"

# WSO2
apim_zip_url: "https://github.com/wso2/product-apim/releases/download/v4.6.0/wso2am-4.6.0.zip"
apim_home: "/home/{{ ansible_user }}/wso2am-4.6.0"
java_home: /usr/lib/jvm/java-1.11.0-openjdk-amd64
```

Adjust values according to the environment.

# How to Run

1. Ensure Ansible is installed on the control node.  
2. Configure SSH access to all target hosts.  
3. Update:
   - `inventory`
   - `vars.yml`  
4. Run:

```bash
ansible-playbook -i inventory playbook.yml --ask-become-pass
```

---

# What This Playbook Does

## MySQL

- Installs `mysql-server`  
- Creates databases before importing SQL  
- Grants privileges on both databases  
- Enables remote access  

## Nginx

- Generates a 365-day self-signed certificate  
- Configures upstream APIM nodes  
- Enables HTTPS routing  
- Removes default Nginx configuration  

## WSO2 APIM

- Installs OpenJDK 11  
- Extracts APIM package  
- Applies node-specific configuration  
- Registers APIM as a systemd service  
- Starts service automatically on boot  

---

# Access URLs

After successful deployment:

```
https://am-uat.<domain_name>
https://api-uat.<domain_name>
```

Since a self-signed certificate is used, browsers will show a security warning.

---

# Notes

- This playbook assumes Ubuntu/Debian-based systems (uses `apt`).  
- Requires Ansible collection:
  - `community.mysql`  
- Ensure firewall rules allow:
  - 3306 (MySQL)  
  - 443 (HTTPS)  
  - Required APIM internal ports  

---

