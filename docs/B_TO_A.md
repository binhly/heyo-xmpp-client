# Path from B to A

Grading rationale and the concrete work items that close the gap. Current
grade: **B** (post-2026-09 fixes). All findings reference real files and
symbols in this repo.

## Why B, not A

1. No integration test drives the real `connect_once` state machine against a
   scripted server — the bugs found in review were exactly this class, and the
   current smoke tests stub internals (`open_transport`, `cleanup_connection`)
   rather than exercising the sequence end-to-end.
2. Client lifecycle (feature negotiation, TLS upgrade, SASL transitions,
   reconnect state) has thin coverage; existing tests mostly cover helpers and
   plugin routing.
3. Protocol scope is narrow but undocumented: PLAIN only (no SCRAM-SHA-1), no
   stream resumption (XEP-0198), no stringprep JID validation. Fine for the
   MongooseIM target, but the README does not say so.
4. Minor debt: legacy shim, coarse error taxonomy, unvalidated tag-name
   interpolation, incomplete failure-path handling.

## Work items

### 1. Lifecycle integration test harness (highest value)

Build a scripted-server harness that feeds raw bytes through a socket pair and
drives the real `Xmpp::Client#connect_once` / `listen` / reconnect paths
without stubbing client internals. This single item would have caught both
broken flows found in review.

Scenarios to cover:

- Full happy path: features → STARTTLS (needs a real TLS socket pair or a
  pluggable transport seam) → PLAIN auth → bind → session.
- Token-auth (X-OAUTH) rejection → stream restart → PLAIN fallback completes
  (asserts the `@plain_fallback_disabled` one-shot flag ordering).
- Server without STARTTLS under `use_tls: :starttls` → `Xmpp::Error`, no
  password bytes ever written to the wire.
- STARTTLS `<failure/>` response → immediate `Xmpp::Error`.
- Stream drop mid-IQ with `reconnect: true` → backoff loop → reconnected;
  and the nested-reconnect guard (`@reconnecting`) raising instead of
  deadlocking when a plugin's `on_connect` IQ fails during reconnect.
- Ping liveness: silent server → socket closed → consumer thread observes the
  error and reconnect runs on the consumer thread (not the ping thread).

Acceptance: `test/` gains a `client_lifecycle_test.rb` that uses no `stub` on
private methods; failure of any scenario fails the suite.

### 2. Move smoke tests off private-API stubs

`test/client_fixes_smoke_test.rb` currently reaches into
`instance_variable_set` and singletons. Once item 1's harness exists, rewrite
these tests against the public surface (`connect`, plugin API) and delete the
private-API access. Tests that must touch internals become `client_internal_test.rb`
cases with a stated justification.

### 3. Document protocol scope honestly (README)

Add a "Scope and limitations" section:

- Auth mechanisms supported: PLAIN and MongooseIM X-OAUTH
  (`erlang-solutions.com:xmpp:token-auth:0`). No SCRAM; PLAIN requires TLS.
- No XEP-0198 stream resumption; reconnection is full re-handshake.
- JIDs are split on `@`/`/` (`Xmpp::Client#parse_jid`); no stringprep
  (RFC 7622). Non-ASCII/localpart-edge-case JIDs are untested.
- Target server: MongooseIM. Generic RFC 6120 servers work for the covered
  subset but are not CI-tested.

Acceptance: a reader can decide in one screen whether this gem fits their
server.

### 4. Error taxonomy

`Xmpp::Error` exists; use it consistently:

- `Xmpp::AuthenticationError < Error` for SASL failures (PLAIN `<failure/>`
  currently raises a generic `Error`; include the server's `<failure>` child
  element, e.g. `<not-authorized/>`).
- `Xmpp::ProtocolError < Error` for stream violations (duplicate stream
  header, malformed bind result).
- Keep `TimeoutError` as-is; it already subclasses `Xmpp::Error`.

Acceptance: every `raise` in `lib/xmpp/` uses an `Xmpp::` error class; no bare
strings.

### 5. Hygiene cleanup

- Delete `lib/xmpp_client.rb` (one-line legacy shim duplicating
  `lib/heyo_xmpp_client.rb`). Breaking change; bump to 0.3.0.
- `Xmpp::Plugins::MucLight#set_configuration` and `#build_create_body`
  interpolate keyword keys into XML tag names (`muc_light.rb`). Validate keys
  against `/\A[a-z][a-z0-9_-]*\z/i` before interpolation.
- `heyo_xmpp_client-0.1.0.gem` artifact in the working tree vs
  `VERSION = "0.2.0"` — remove from disk; ensure `.gitignore` covers
  `*.gem`.
- `bind_resource` silently leaves `full_jid` nil on a malformed bind result —
  raise `ProtocolError` instead.

### 6. Optional (A+ territory, not required for A)

- SCRAM-SHA-1 support (removes the PLAIN-over-TLS-only constraint).
- XEP-0198 stream resumption for fast reconnects.
- CI matrix running the suite against Ruby 3.0–3.4 (the gemspec claims
  `>= 3.0`; `Socket.tcp(connect_timeout:)` is safe, but nothing verifies it).

## Sequencing

1 → 2 → 3 are the grade movers; 4 and 5 are half-days each and can interleave.
Item 1's harness is the prerequisite for trusting any future change to
`connect_once`/`authenticate`, so it goes first.

## Out of scope for A

Broadening beyond the MongooseIM target (full XEP matrix, general-purpose
client parity with xmpp4r/Blather) is a product decision, not a quality gap.
A grade reflects "excellent at what it claims to be", given the scope is
documented per item 3.
