---
title: "<PROGRAM>: <VULNERABILITY> in <FEATURE_OR_ENDPOINT>"
date: YYYY-MM-DD HH:MM:SS +0700
categories: [Writeups, Bug Bounty]
tags:
  - <PROGRAM>
  - <VULNERABILITY_TYPE>
  - web-security
  - AI # Keep exactly one of: AI, Human, AI & Human
permalink: /posts/<program>-<finding-slug>/
---

> **Summary:** <ONE_OR_TWO_SENTENCES_DESCRIBING_THE_ROOT_CAUSE_AND_IMPACT>
{: .prompt-info }

## Finding Overview

<CONTEXT_AND_THE_SECURITY_PROPERTY_THAT_FAILED>

## Finding at a Glance

| Field | Value |
|---|---|
| Program | <PROGRAM> |
| Asset | <IN_SCOPE_ASSET> |
| Affected endpoint | `<ENDPOINT>` |
| Vulnerability | <VULNERABILITY_TYPE> |
| Impact | <MEASURABLE_IMPACT> |

## Attack Path

```text
<ATTACKER_CONTROLLED_INPUT>
-> <ROOT_CAUSE>
-> <PRIVILEGED_ACTION_OR_DATA_ACCESS>
-> <IMPACT>
```

## Initial Observation

<HOW_THE_RELEVANT_FUNCTIONALITY_WAS_DISCOVERED>

## Root Cause

<THE_TRUST_OR_AUTHORIZATION_FAILURE>

## Reproduction

### <STEP_OR_PAYLOAD>

<SAFE_REPRODUCTION_STEPS_AND_EVIDENCE>

## Impact

<WHO_IS_AFFECTED_AND_WHAT_THE_ATTACKER_CAN_ACHIEVE>

## Remediation

<SPECIFIC_FIXES_AND_DEFENSE_IN_DEPTH>

## Takeaways

- <LESSON_ONE>
- <LESSON_TWO>

## Disclosure Note

<PUBLICATION_STATUS_AND_ANY_REDACTIONS>
