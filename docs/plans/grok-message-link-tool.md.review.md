# Grok Bot Messages link tool plan review

## Review setup

Triage selected Security Auditor, Saboteur, and New Hire because the plan moves
a production secret, adds external network I/O, changes authenticated MCP
behavior, and introduces an offline capability. The preferred Claude Opus lane
was attempted twice. The first invocation used an invalid CLI argument order;
the corrected invocation failed because the Claude OAuth session was expired
and could not be refreshed. Three independent Codex contexts were used as the
strongest available substitute.

## Traceability

| # | Severity | Persona | Finding | Disposition | Edit location | Verified? |
|---|---|---|---|---|---|---|
| 1 | CRITICAL | New Hire / Saboteur / API review | A relay-only offline catalog would hide Mac-backed tools with no usable list-change notification path | ACCEPT | Implementation 5; relay acceptance tests | ✅ |
| 2 | CRITICAL | New Hire | Named Grok personas versus all remote clients was ambiguous | ACCEPT | Scope and trust boundary | ✅ |
| 3 | CRITICAL | New Hire | Exact phone and Unicode validation contract was unspecified | ACCEPT | Implementation 1 | ✅ |
| 4 | CRITICAL | Saboteur | Relay-owned calls could bypass single-flight and create too many links | ACCEPT | Implementation 6; relay acceptance tests | ✅ |
| 5 | CRITICAL | Security / API review | Existing read/draft tokens would silently gain seven-day cloud persistence and public bearer-link authority | ACCEPT | Dedicated `messages:link` scope, token policy 2, browser and Mac disclosure, negative auth tests | ✅ |
| 6 | WARNING | Security / New Hire | Redirects, response size, timeout value, and retry semantics were unspecified | ACCEPT | Implementation 2; unit tests | ✅ |
| 7 | WARNING | Security | Downstream HTML/URL rendering boundary lacked malicious-text regressions | ACCEPT | Implementation 9 | ✅ |
| 8 | WARNING | Security / New Hire | No-log promise was not tested outside returned errors | ACCEPT | Tests and acceptance evidence | ✅ |
| 9 | WARNING | Security / Saboteur | Future expiry did not enforce the promised seven-day retention | ACCEPT | Implementation 2; unit tests | ✅ |
| 10 | WARNING | Security / Saboteur | Ambiguous failure could create an orphan link and a retry duplicate | ACCEPT | Implementation 2; unit and relay tests | ✅ |
| 11 | WARNING | Saboteur / API review | HTTP 429 would prevent standard MCP clients from parsing the tool-level limit result | ACCEPT | Implementation 6; standard SDK acceptance test | ✅ |
| 12 | WARNING | Saboteur | One persona did not prove discovery for all three named personas | ACCEPT | Final live confidence boundary | ✅ |
| 13 | WARNING | New Hire | Credentialed deployment lacked canonical identifiers and secret source | ACCEPT | Post-merge acceptance step | ✅ |
| 14 | WARNING | Security / Saboteur | Code rollback did not contain token compromise or minted links | ACCEPT | Rollback | ✅ |
| 15 | WARNING | Security | Per-call idempotency key was recommended | DEFER | Follow-up only if safe transparent retries become a requirement | ✅ |

## Deferred finding

The opener API has no idempotency contract. This release deliberately performs
one request and returns an explicit `outcome_unknown` error after a dispatched
timeout, network failure, or malformed 201 response, instructing agents not to
retry automatically.
Adding replay persistence would enlarge the data model and is unnecessary for
the current user-confirmed workflow. If transparent retries become a product
requirement, idempotency must be designed in both the relay and opener service.

## Verdict

**CLEAN.** Every critical finding is addressed. The remaining deferred item is
bounded by an explicit single-attempt and no-auto-retry contract.
