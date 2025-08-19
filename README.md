# 🔐 Wazuh Docker – Change Indexer User Passwords

This repository provides a helper script to **update Wazuh Indexer internal users’ passwords** (`admin` or `kibanaserver`) in a Docker-based deployment.

As with every Wazuh installation I set up in Docker, there are a few tasks that quickly become part of the routine. And like any sysadmin (lazy by nature 😅), I prefer to automate them instead of repeating the manual steps over and over.  

This script was built exactly for that: to **accelerate and simplify the password change process** for internal users. What normally requires multiple manual steps, is now a single command.

## 📋 Features

- Generate password hash using the `wazuh/wazuh-indexer:<tag>` image  
- Update `internal_users.yml` with the new hash  
- Update `docker-compose.yml` and `.env` (if present)  
- Recreate the Docker stack automatically  
- Apply the changes via `securityadmin.sh` inside the Indexer container  
- Optionally verify the new password with an HTTP 200 test  

## 📦 Requirements

- Linux host with Docker / Docker Compose  
- A running Wazuh Docker stack (single-node or multi-node)  
- Access to the Indexer container (e.g. `single-node-wazuh.indexer-1` or `multi-node-wazuh1.indexer-1`)  
- Standard Linux utilities: `bash`, `awk`, `sed`, `curl`  

## 🚀 Usage

```bash
./wazuh-docker-change-password.sh [options]
-d <dir>                 Stack directory (where docker-compose.yml is located). Default: .
-U <user>                Target user: admin | kibanaserver
-P <password>            New password (if omitted, will be prompted)
--old-password <pass>    Old password (optional, for validation)
--indexer-container <c>  Force Indexer container name
--indexer-tag <tag>      Image tag used to generate hash. Default: 4.12.0
--wait-secs <n>          Dynamic wait timeout (default: 120)
-H, --hash-only          Only generate/print password + hash (no changes) and exit
-h, --help               Show help
```

## 💡 Examples

Change the admin password inside a multi-node stack:

```bash
./wazuh-docker-change-password.sh -d /opt/wazuh-docker/multi-node \
  -U admin -P 'NewP@ssw0rd!' --old-password 'SecretPassword'
```

Generate only the password hash (no config changes applied):

```bash
./wazuh-docker-change-password.sh -H -P 'NewP@ssw0rd!'
```

## 🔍 Verification

After applying, the script tests the new (and optionally the old) password:

```bash
curl -ks -u admin:NewP@ssw0rd! https://<indexer_host>:9200
```

A successful change will return HTTP 200.

## ⚠️ Notes

If the Wazuh Indexer container takes time to initialize, adjust --wait-secs.
If container name detection fails, specify it with --indexer-container <name>.
Always backup your config files before applying changes.

## 📖 Credits
 Script authored and tested by mjvmst, with a little help from AI (ChatGPT) 😉
