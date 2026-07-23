---
title: "HTB MakeSense Write-up: Stored XSS to Root OCR RCE"
date: 2026-07-23 10:10:00 +0700
categories: [Writeups, HackTheBox]
tags: [HackTheBox, Linux, WordPress, stored-xss, AES-GCM, credential-reuse, OCR, RCE, privilege-escalation, Season 11, AI]
permalink: /posts/htb-makesense-writeup/
image:
  path: /assets/img/posts/htb/makesense.png
  alt: "Official Hack The Box MakeSense machine avatar"
---

> **Summary:** MakeSense chains a client-exposed encryption key, stored XSS in a WordPress contact workflow, administrator plugin upload, leaked SSH credentials, and a root-run OCR service that writes PHP files to obtain root.
{: .prompt-info }

## Machine Information

| Field | Value |
|---|---|
| Machine | MakeSense |
| Platform | Hack The Box |
| OS | Linux |
| Difficulty | Medium |

## Attack Path

```text
Public JavaScript encryption key
-> forged voice-result submission
-> stored XSS in WordPress admin
-> create WordPress administrator
-> plugin upload RCE as www-data
-> SSH credential from wp-config.php
-> walter user shell
-> root-run localhost OCR service
-> PHP file write in web root
-> root
```

## Enumeration

The target exposed SSH and HTTPS. The certificate identified `makesense.htb`, which hosted a WordPress site with a custom voice/contact workflow.

Two JavaScript assets were relevant:

```text
/wp-content/themes/webagency/assets/js/main.js
/wp-content/themes/webagency/assets/js/whisper-wrapper.js
```

The code exposed public AJAX actions, an AJAX nonce, and a client-side encryption key used to protect voice results. The WordPress REST API also disclosed an `admin` user.

## Initial Access

### Forged encrypted voice results

The site used AES-GCM but embedded its key in public JavaScript. Anyone could derive the AES key, encrypt an arbitrary JSON object, and submit it through the public `save_voice_results` AJAX action.

```json
{
  "transcription": "normal transcript",
  "summary": "attacker-controlled HTML"
}
```

The submission workflow was:

1. Load the home page and extract the AJAX nonce.
2. Send `submit_contact_form` to receive a `post_id`.
3. Send `save_voice_results` with that ID, nonce, and the forged encrypted payload.

### Stored XSS to WordPress administrator

The contact-review interface rendered the controlled voice summary unsafely in WordPress admin. A stored XSS payload ran in the reviewing administrator's session and created a second WordPress administrator account.

The exact JavaScript is omitted to keep the public write-up non-weaponized. Its required actions were to obtain the user-creation nonce from `/wp-admin/user-new.php` and submit the normal `createuser` form with the administrator's existing session.

## User Access

### WordPress administrator to web-server execution

With WordPress administrator access, plugin upload provided command execution as `www-data`. The plugin body and command wrapper are replaced with placeholders so endpoint protection does not flag the article; an authorized lab reproduction can verify the same access with a harmless command such as `id`.

```text
uid=33(www-data) gid=33(www-data)
```

### SSH as `walter`

`wp-config.php` included an SSH credential for `walter`. It provided an SSH session and access to:

```text
/home/walter/user.txt
```

## Privilege Escalation

### Root-run OCR service writing PHP files

Process enumeration revealed a root-owned PHP development server listening on localhost port `8001`:

```text
root  php -S <LOCALHOST_IP>:8001 -t /root/ocr4/
```

The service accepted Walter's Basic Auth credentials. It rendered submitted text to an image, performed OCR, and allowed the recognized text to be saved under a caller-supplied filename.

Because the service ran as root and allowed a `.php` filename under its own PHP document root, a user could make it save a controlled PHP command wrapper and then request that file. A harmless `id` request returned root context:

```text
uid=0(root) gid=0(root)
```

The root flag was available at:

```text
/root/root.txt
```

## Vulnerabilities / Weaknesses Used

### Client-side encryption key exposure

The AES-GCM key was delivered to every visitor in JavaScript, so the encrypted format did not establish trust in submitted content.

### Stored XSS in an administrator-reviewed field

The application accepted untrusted voice summaries and rendered them without safe output encoding in a privileged WordPress context.

### WordPress administrator plugin upload

An administrator could upload executable plugin code, converting WordPress administrative access into web-server command execution.

### Credential exposure in `wp-config.php`

The WordPress configuration contained a valid SSH password for a local Linux user.

### Root service file-write-to-RCE

The OCR server ran as root and wrote attacker-controlled content to a PHP-executable location, turning file write into root command execution.

## Takeaways

- Client-side encryption cannot protect a server-side trust boundary when the key is public.
- Never render user-supplied data in administrative interfaces without context-appropriate output encoding.
- Treat WordPress administrator access as code-execution-equivalent when plugin upload is enabled.
- A privileged service must not write untrusted content into an executable web root.
