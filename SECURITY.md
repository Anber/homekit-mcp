# Security model

The audited upstream baseline is `69d1ebb44d1fd52c2b5dd5e5e43092e484f284e4`. This fork replaces its network server, policy model, mutation dispatch and room planner.

## Trusted boundary

The macOS account, Apple frameworks, configured signing identity, local source/binary and processes running as the same UID are trusted. Root and a compromised account can change the policy, read journals or impersonate the local client. File permissions and peer checks protect against other ordinary local users; there is no network-facing listener for browsers or LAN hosts.

HomeKit permission is an Apple-level application grant. The narrower home/accessory/room policy is enforced by this adapter on the server side, including direct calls to tools not listed in read-only mode. Do not confuse the HA bridge's exposure list with this adapter's policy; they are different boundaries.

## Writes and recovery

Only metadata changes are implemented. Native HomeKit is asynchronous and does not offer an atomic compare-and-swap transaction spanning multiple accessories or apps. The adapter checks expected identity/state immediately before acceptance and verifies state after callbacks. Another Home app can still change state concurrently; an inconsistent read-back is unconfirmed and blocks further mutations.

Before acceptance, an owned private journal is atomically written, file/directory synced and flushed with macOS F_FULLFSYNC. This fails closed on storage errors or unsupported filesystem semantics. A journal records the pre-change allowed inventory, request fingerprint and operation identity. It is sensitive household metadata, not a credential store. Keep it private and out of source control/backups shared publicly.

Accepted operations cannot be cancelled reliably at the HomeKit layer. A disconnected client or Stop is never proof that the operation failed. Poll an existing operation or inspect fresh inventory and its private journal; never blindly create a new request UUID for a timed-out write. Pending/unconfirmed durable records prevent write-mode restart until an operator inspects and archives them. Completed UUIDs remain idempotent while their records are retained. Archiving them ends that historical duplicate protection.

Bulk plans are best-effort sequential metadata updates, not a transaction. Fresh whole-plan preflight, per-operation checks, before snapshots and post-read-back do not create an atomic all-or-nothing Apple API. If a later operation fails, stop and reconcile using the snapshot.

## Transport

One user-owned AF_UNIX endpoint, same-UID peer validation, four concurrent connections, bounded one-MiB newline frames and read/write timeouts. The production dispatcher is tested through the real transport with a fake HomeKit backend. Python stdio output is protocol-only. There is no HTTP parser, CORS policy, socket proxy exposed over TCP, automatic updater, login service, external runtime package or HomeKit token export.

## Verification still requiring a real signed app

Unsigned build/typechecking and fixture tests cannot prove Apple provisioning, TCC entitlement acceptance, actual HomeKit permissions or native mutation callbacks. Before real use, inspect the signed app's entitlements and validate narrow read-only inventory first. Only then opt into selected metadata writes and verify one reversible rename/move before bulk changes.

There is no guarantee that every bug or malicious change is detectable by static review. Re-review upstream changes; do not replace this pinned source with an unreviewed release binary.
