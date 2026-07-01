---
title: "SekaiCTF2026: [Web/0day]Migurimental - Next.js Middleware Bypass and Cookie Confusion"
date: 2026-07-01 10:00:00 +0700
categories: [Writeups, Web Security]
tags: [SekaiCTF, web, Next.js, middleware-bypass, SSR, cookie-confusion, access-control, CTF, 0day]
permalink: /posts/sekaictf-migurimental-nextjs-middleware-bypass/
---

> **Summary:** I solved Migurimental by abusing several authorization mismatches in a pair of Next.js applications. The first app leaked Miku's access-card data through a Next.js data route, then a duplicate-cookie parsing mismatch let me enter the backroom as Miku. The second app leaked the remaining flag half through a prefixed Next.js data route.
{: .prompt-info }

## Introduction

This write-up covers my solution for **Migurimental**, a web challenge from SekaiCTF authored by **beluga**.

| Challenge    | Category | Difficulty | Points | Solves |
|--------------|----------|------------|--------|--------|
| Migurimental | Web      | Easy       | 50    | 156      |

The challenge description was:

> Poor migu lost her leek

The challenge also came with a 0day note asking players to keep the underlying issue private until the relevant vulnerability was patched. For that reason, this write-up stays focused on the challenge-specific chain instead of turning the bug into a general-purpose advisory.

The challenge had two live services:

- `https://migurimental.chals.sekai.team`
- `https://migurimental-2.chals.sekai.team`

The flag was split between the two services. The first half was hidden behind Miku's backroom page, and the second half was exposed through the second service.

## Target

- **CTF:** SekaiCTF
- **Author:** beluga
- **Category:** Web
- **Win condition:** Recover both halves of the flag from the two Migurimental services
- **Main bug class:** Next.js middleware authorization mismatch

## Initial Observation

After unpacking the attachment, the application looked like a standard Next.js service with middleware-based access control. A normal user could register, receive a session, and then visit their own access card:

```text
/access-card?id=<own_id>
```

The intended authorization rule was simple: users should only be able to view their own access card, and only a valid ticket holder should be able to enter the backroom.

The important pattern was that the middleware performed the access checks, while the server-side page logic loaded data using request parameters and cookies. Those two layers did not always agree on which value was authoritative.

## Root Cause

The first issue was a parameter mismatch on the Next.js data route for `/access-card`.

The middleware checked one parameter, while the server-side page logic used another parameter to load the user. By calling the internal data route directly, I could make the middleware validate my own user ID while the SSR page loaded Miku's user ID instead:

```text
/_next/data/<BUILD_ID>/access-card.json?nxtPid=<own_id>&id=1
```

In this request:

- `nxtPid=<own_id>` satisfied the middleware check.
- `id=1` was still used by the page logic to fetch the displayed user.
- User ID `1` belonged to `miku`.

The second issue was a cookie parsing mismatch on `/backroom`.

The middleware and the SSR page disagreed on duplicate cookies. With two `ticket_uuid` cookies in the same header, one layer used the last value and the other layer used the first value:

```text
Cookie: ticket_uuid=<MIKU_TICKET>; session=<OWN_SESSION>; ticket_uuid=<OWN_TICKET>
```

That made the middleware see my own valid ticket, while the SSR page loaded the backroom data for Miku's ticket.

The final issue was on the second service. The app used an asset prefix of `/cdn`, which allowed the Next.js data route to be requested through the prefixed path:

```text
/cdn/_next/data/<BUILD_ID>/index.json
```

That route was not covered by the same middleware behavior, so it returned the page data containing the second half of the flag.

## Exploit

The full exploit chain was:

1. Register a fresh user on the first service.
2. Extract the new user's ID, session cookie, and ticket UUID.
3. Get the first service's Next.js build ID.
4. Call the `/access-card` data route with `nxtPid=<own_id>` and `id=1`.
5. Decode Miku's QR data URL from the JSON response.
6. Extract Miku's `ticket_uuid` from the QR code.
7. Request `/backroom` with duplicate `ticket_uuid` cookies.
8. Read the first half of the flag.
9. Get the second service's Next.js build ID.
10. Request `/cdn/_next/data/<BUILD_ID>/index.json`.
11. Read the second half of the flag and concatenate both parts.

The first data-route request returned Miku's access-card information:

```json
{
  "pageProps": {
    "user": {
      "id": 1,
      "username": "miku",
      "tier": "VIP"
    },
    "qrDataUrl": "data:image/..."
  }
}
```

After decoding the QR code, I recovered Miku's ticket UUID:

```text
92ca07cc-13bd-4d2b-b6b3-e8399790078a
```

Then I used the duplicate-cookie trick against `/backroom`:

```http
Cookie: ticket_uuid=92ca07cc-13bd-4d2b-b6b3-e8399790078a; session=<OWN_SESSION>; ticket_uuid=<OWN_TICKET>
```

The middleware accepted the request because it validated my own ticket, but the SSR page rendered the backroom for Miku's ticket.

## Exploitation Output

I automated the chain with a Python script:

```text
$ python3 solve_migurimental.py \
    https://migurimental.chals.sekai.team \
    https://migurimental-2.chals.sekai.team
```

The script registered a user, recovered Miku's ticket from the access-card QR code, used the duplicate-cookie parsing mismatch to reach the backroom, and then queried the prefixed data route on the second service.

The final output was:

```text
[+] first half: SEKAI{7h3_l33k_15_b4ck_7h3_cr0wd_15_ch33r1ng_4nd_7h3_
[+] second half: c0nc3r7_c4n_f1n4lly_b3g1n_m1ku_m1ku_b34mmmmmmmmmmmm}

[+] FLAG CANDIDATE:
SEKAI{7h3_l33k_15_b4ck_7h3_cr0wd_15_ch33r1ng_4nd_7h3_c0nc3r7_c4n_f1n4lly_b3g1n_m1ku_m1ku_b34mmmmmmmmmmmm}
```

## Result

```text
SEKAI{7h3_l33k_15_b4ck_7h3_cr0wd_15_ch33r1ng_4nd_7h3_c0nc3r7_c4n_f1n4lly_b3g1n_m1ku_m1ku_b34mmmmmmmmmmmm}
```