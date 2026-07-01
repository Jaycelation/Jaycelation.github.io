---
title: "Intigriti LeakyJar: Forcing the Master Baker to Share the Admin Vault with CSRF"
date: 2026-07-01 00:00:00 +0700
categories: [Writeups, Web Security]
tags: [Intigriti, LeakyJar, CSRF, admin-bot, bug-bounty, web-security]
permalink: /posts/intigriti-leakyjar-csrf-admin-vault/
---

> **Summary:** I solved the Intigriti LeakyJar challenge by abusing a missing CSRF protection on `/share`. By making the Master Baker bot visit an attacker-controlled page, I could force the admin session to share the admin vault with my account and read the flag from the shared recipe box.
{: .prompt-info }

## Introduction

This write-up covers my solution for the Intigriti LeakyJar challenge.

The application had a vault feature where users could store recipe boxes and share them with other users. The interesting part was that sharing a vault was implemented as a state-changing `POST` request to `/share`.

At first, this looked like a normal authenticated feature. However, the request did not require a CSRF token, and the application also had a Master Baker/admin bot that visited attacker-submitted URLs.

That combination made the issue exploitable. I hosted a page that automatically submitted a form to `/share`, submitted that page to the bot, and let the admin's browser perform the share action with the admin session.

The result was that the Master Baker's private vault appeared under my account's shared vaults, exposing the secret recipe that contained the flag.

## Target

- **Challenge:** Intigriti LeakyJar
- **Asset:** `https://leakyjar.intigriti.io`
- **Vulnerable endpoint:** `/share`
- **Bot trigger:** `/submit`
- **Vulnerability type:** Cross-Site Request Forgery
- **Impact:** Forced admin vault sharing and private data disclosure

## Initial Observation

The application allowed users to register, log in, and access their recipe vault:

```text
/register
/login
/vault
```

There was also a submission feature:

```text
/submit
```

This feature caused the Master Baker/admin bot to visit a URL submitted by the user.

The important application feature was vault sharing. A logged-in user could share their recipe box with another user by sending a request like this:

```http
POST /share HTTP/1.1
Host: leakyjar.intigriti.io
Content-Type: application/x-www-form-urlencoded

username=ATTACKER_USERNAME
```

After the request succeeded, the target user could open `/vault` and see a new entry under the shared vaults section.

## The Vulnerable Share Flow

The `/share` endpoint performed a sensitive state-changing action: it shared the currently authenticated user's vault with another account.

However, the request only needed the target username.

There was no per-request CSRF token, no visible anti-CSRF parameter, and no additional confirmation step. This meant a third-party website could create the same request using a plain HTML form.

Because the action was authenticated by cookies, the browser would attach the victim's session cookie when the form was submitted from an attacker-controlled page, as long as the cookie policy allowed it.

In this challenge, the Master Baker bot visited attacker-submitted URLs while logged in, so the missing CSRF protection became directly exploitable against the admin account.

## Root Cause

The root cause was that `/share` trusted the user's session cookie as proof of intent.

The endpoint changed server-side state but did not verify that the request came from a legitimate in-application form.

The missing controls were:

- No CSRF token in the share form.
- No CSRF token validation on `POST /share`.
- No effective origin validation for the state-changing request.
- No confirmation step before sharing a private vault.

This allowed an attacker to force an authenticated user to share their own vault with an attacker-controlled account.

## CSRF Payload

The payload was a basic auto-submitting HTML form:

```html
<!doctype html>
<html>
<body>
  <form id="share-box" action="https://leakyjar.intigriti.io/share" method="POST">
    <input type="hidden" name="username" value="ATTACKER_USERNAME">
  </form>

  <script>
    document.getElementById("share-box").submit();
  </script>
</body>
</html>
```

The only value that needed to be changed was:

```text
ATTACKER_USERNAME
```

That value had to be replaced with the username of my attacker account.

## Exploit Flow

The full exploit flow was:

1. Register an attacker account on `https://leakyjar.intigriti.io/register`.
2. Log in as the attacker.
3. Host the CSRF payload on a public HTTPS URL.
4. Replace `ATTACKER_USERNAME` with the attacker's username.
5. Submit the hosted payload URL through `/submit`.
6. The Master Baker bot visits the attacker-controlled page.
7. The page automatically submits a `POST` request to `/share`.
8. The browser sends the request with the Master Baker's authenticated session.
9. The application shares the admin vault with the attacker account.
10. The attacker opens `/vault` and finds the Master Baker's vault under shared vaults.
11. Opening the shared vault reveals the private recipe containing the flag.

## Proof of Concept

### 1. Register an Attacker Account

I first created a normal user account:

```text
https://leakyjar.intigriti.io/register
```

This account was the account that would receive the shared admin vault.

### 2. Host the Payload

I hosted the auto-submit form on a public HTTPS endpoint:

```html
<!doctype html>
<html>
<body>
  <form id="share-box" action="https://leakyjar.intigriti.io/share" method="POST">
    <input type="hidden" name="username" value="ATTACKER_USERNAME">
  </form>

  <script>
    document.getElementById("share-box").submit();
  </script>
</body>
</html>
```

The final request generated by the browser was equivalent to:

```http
POST /share HTTP/1.1
Host: leakyjar.intigriti.io
Content-Type: application/x-www-form-urlencoded

username=ATTACKER_USERNAME
```

### 3. Submit the Payload URL

I submitted the hosted URL to the bot through:

```text
https://leakyjar.intigriti.io/submit
```

When the Master Baker visited the page, the form submitted automatically.

From the application's perspective, this looked like the Master Baker intentionally submitted the share form, because the request was sent with the Master Baker's valid session cookie.

### 4. Read the Shared Vault

After the bot visited the payload, I returned to:

```text
https://leakyjar.intigriti.io/vault
```

A new entry appeared under the shared vaults section.

Opening that shared vault exposed the Master Baker's private recipe box. The secret recipe contained the flag:

```text
INTIGRITI{019ef404-1e44-7748-bdcf-ca7b12dbfee0}
```

## Why This Leaks Admin Data

The attacker never needs to know the admin's password or steal the admin's session cookie.

Instead, the attacker abuses the browser's normal cookie behavior. The Master Baker is already authenticated, and the browser automatically attaches the admin session cookie to the forged request.

Because `/share` does not distinguish between a legitimate in-app request and a forged cross-site form submission, the server accepts the action and shares the admin vault with the attacker.

This turns a CSRF bug into a direct private data disclosure issue.