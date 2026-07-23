---
title: "HTB Enigma Write-up: NFS Leak to OliveTin Root"
date: 2026-07-23 10:00:00 +0700
categories: [Writeups, HackTheBox]
tags: [HackTheBox, Linux, NFS, Roundcube, OpenSTAManager, CVE-2025-69212, OliveTin, command-injection, privilege-escalation, Season 11, AI]
permalink: /posts/htb-enigma-writeup/
image:
  path: /assets/img/posts/htb/enigma.png
  alt: "Official Hack The Box Enigma machine avatar"
---

> **Summary:** Enigma chains a world-readable NFS share, credential reuse through webmail, OpenSTAManager ZIP-import command injection, and an injectable root-run OliveTin action to obtain root.
{: .prompt-info }

## Machine Information

| Field | Value |
|---|---|
| Machine | Enigma |
| Platform | Hack The Box |
| OS | Linux |

## Attack Path

```text
NFS onboarding document
-> kevin webmail credentials
-> sarah password reuse
-> OpenSTAManager admin credentials
-> ZIP/P7M import command injection
-> www-data
-> crack haris password hash
-> OliveTin backup-action injection
-> root
```

## Enumeration

The relevant services were SSH, HTTP, mail protocols, and NFS:

```text
22/tcp    ssh
80/tcp    http
110/tcp   pop3
143/tcp   imap
993/tcp   imaps
995/tcp   pop3s
2049/tcp  nfs
```

The web server used three virtual hosts:

```text
enigma.htb
mail001.enigma.htb
support_001.enigma.htb
```

## Initial Access

### World-readable NFS onboarding share

The NFS export list exposed a world-readable onboarding share:

```bash
showmount -e <TARGET_IP>
```

```text
/srv/nfs/onboarding *
```

Mounting the share revealed `New_Employee_Access.pdf`. Extracting its text disclosed valid Roundcube credentials for `kevin`.

### Webmail password reuse

The `kevin` account worked at `mail001.enigma.htb`. Its mailbox pointed to Sarah in Accounts, and the same password was valid for her IMAP account. Sarah's mailbox contained OpenSTAManager administrator credentials for `support_001.enigma.htb`.

### OpenSTAManager ZIP/P7M import injection

OpenSTAManager 2.9.8 was vulnerable to CVE-2025-69212. During ZIP import, a `.p7m` entry name reached an `openssl smime` shell invocation without safe argument handling.

The proof of concept used a ZIP entry name that closed the intended quoting context and invoked an authorized-lab command wrapper:

```python
malicious_filename = 'invoice.p7m"; <AUTHORIZED_COMMAND>; echo ".p7m'
```

After import, the controlled wrapper executed as the web-server account:

```text
uid=33(www-data) gid=33(www-data)
```

The original webshell payload is intentionally omitted so the repository remains safe to scan and endpoint protection does not quarantine the article.

## User Access

### Recovering the `haris` credential

The OpenSTAManager configuration disclosed database credentials. Querying `zz_users` returned a bcrypt hash for `haris`, which cracked with Hashcat mode `3200` to the password `bestfriends`.

SSH accepted public keys only, but `su haris` from the web shell accepted the recovered password. The user flag was then available at:

```text
/home/haris/user.txt
```

## Privilege Escalation

### OliveTin backup action injection

Local enumeration exposed OliveTin on `127.0.0.1:1337`. Its readable configuration defined a root-run backup action that interpolated `db_pass` into a shell command in single quotes:

```yaml
shell: "mysqldump -u {{ db_user }} -p'{{ db_pass }}' {{ db_name }} > /opt/backups/backup.sql"
```

An attacker-controlled password value could close that quoting context and append a command. The action was reachable through OliveTin's `StartAction` API; invoking it with a benign proof command confirmed root-context command execution.

```text
/api/olivetin.api.v1.OliveTinApi/StartAction
```

The root flag was accessible at:

```text
/root/root.txt
```

## Vulnerabilities / Weaknesses Used

### Exposed NFS share

The onboarding share allowed any client to obtain a document containing working credentials.

### Password reuse

Kevin and Sarah used the same password, enabling a mailbox pivot with no additional exploit.

### OpenSTAManager import command injection (CVE-2025-69212)

ZIP-entry filenames were incorporated into an `openssl` shell command without strict validation or safe process invocation.

### OliveTin shell interpolation

The root-run action inserted an attacker-controlled password inside shell quotes, turning an input field into a command-injection sink.

## Takeaways

- Restrict NFS exports and never place credentials in broadly accessible onboarding material.
- Prevent password reuse with MFA and distinct, managed credentials.
- Pass untrusted filenames and form values as process arguments, never shell fragments.
- Treat loopback-only automation services as a post-compromise attack surface.
