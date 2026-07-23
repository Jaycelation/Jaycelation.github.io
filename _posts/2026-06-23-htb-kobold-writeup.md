---
title: "HTB Kobold Write-up: MCPJam RCE to Root"
date: 2026-06-23 09:30:00 +0700
categories: [Writeups, HackTheBox]
tags: [HackTheBox, Linux, MCPJam, PrivateBin, Arcane, Docker, RCE, privilege-escalation, AI]
permalink: /posts/htb-kobold-writeup/
---

> **Summary:** Kobold chains an unauthenticated MCPJam Inspector command-execution flaw, a writable PrivateBin volume with template traversal, credential reuse, and Docker host mounting to reach root.
{: .prompt-info }

## Machine Information

| Field | Value |
|---|---|
| Machine | Kobold |
| Platform | Hack The Box |
| OS | Linux |

## Attack Path

```text
VHost enumeration
-> MCPJam unauthenticated command execution
-> shell as ben
-> writable PrivateBin shared volume
-> template traversal command execution
-> Arcane credential reuse
-> Docker container with host filesystem mount
-> root
```

## Enumeration

Nmap identified SSH and an HTTPS service with a certificate for `kobold.htb` and wildcard subdomains. I added the discovered domains locally:

```text
<MACHINE_IP> kobold.htb mcp.kobold.htb bin.kobold.htb
```

VHost enumeration revealed two relevant applications:

```text
mcp.kobold.htb  - MCPJam Inspector
bin.kobold.htb  - PrivateBin
```

## Initial Access

### MCPJam Inspector unauthenticated command execution

The MCPJam Inspector endpoint at `/api/mcp/connect` accepted a server configuration with attacker-controlled command and argument fields without authentication. Submitting a controlled configuration yielded a shell as `ben`.

```text
uid=1000(ben) gid=1000(ben)
```

The exact callback command is intentionally omitted; it is sufficient to reproduce the issue with a harmless command such as `id` in an authorized lab.

## User Access

The user flag was accessible as `ben` at:

```text
/home/ben/user.txt
```

## Post-Exploitation

### Internal services and writable data

Local enumeration showed an internal PrivateBin container and the Arcane Docker-management service:

```text
127.0.0.1:8080  - internal PrivateBin container
*:3552           - Arcane Docker management service
```

The `ben` account belonged to the `operator` group and could write to the PrivateBin data volume:

```text
/privatebin-data/data
```

### PrivateBin template traversal

PrivateBin had template selection enabled. A command wrapper placed in the writable shared volume could be included through the `template` cookie using path traversal:

```bash
curl -sk 'https://bin.kobold.htb/?cmd=id' \
  -H 'Cookie: template=../data/<command-wrapper>'
```

This executed as the PrivateBin web user. The original webshell source is deliberately replaced with a placeholder so endpoint-protection software does not quarantine the write-up; use a harmless command wrapper only in the authorized HTB lab.

### Credential reuse into Arcane

The PrivateBin configuration contained application credentials. The password was reused by the Arcane service on port `3552`, which provided Docker container management after login.

## Privilege Escalation

### Docker host filesystem mount

From Arcane, I created a container as root and mounted the host filesystem into it:

```text
Image: privatebin/nginx-fpm-alpine:2.0.2
User: 0:0
Volume mount: /:/hostfs
Entrypoint: /bin/sh
Command: -c "sleep 3600"
```

The container ran as root, and `/hostfs` exposed the underlying host filesystem. The root flag was readable at:

```text
/hostfs/root/root.txt
```

## Vulnerabilities / Weaknesses Used

### MCPJam Inspector unauthenticated RCE

The Inspector trusted attacker-supplied process configuration and launched it without authentication.

### PrivateBin template path traversal

The `template` cookie accepted traversal sequences, allowing a file from a writable shared volume to be included by the web application.

### Credential reuse

An application password found in the PrivateBin configuration was valid for the Arcane management interface.

### Docker management abuse

Allowing a user to create a root container with a host filesystem mount is equivalent to granting host-level root access.

## Takeaways

- Treat MCP server process-launcher settings as highly sensitive administration functionality.
- Keep writable data directories outside template or code-loading paths.
- Do not reuse credentials across application boundaries.
- Restrict Docker management so users cannot create privileged containers or mount the host filesystem.
