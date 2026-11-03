# HomeKit Local

A security-focused fork of [TimCinel/homekit-mcp](https://github.com/TimCinel/homekit-mcp), starting from commit `69d1ebb44d1fd52c2b5dd5e5e43092e484f284e4`.

This fork maintains Apple Home **inventory, accessory names, room names and room assignments**. It does not expose light, lock, garage, cover-position or other actuator commands. Those functions belong to the user's existing automation system.

## Boundaries

- No HTTP or TCP listener. A native Mac Catalyst app owns a Unix-domain socket; a Python standard-library relay speaks MCP over stdio.
- Runtime directory must be owned by the current user with mode `0700`; socket and policy/journal files are `0600`. The server verifies the peer UID. Processes running as your own macOS user are inside this trust boundary; this is not a sandbox against a compromised account.
- First launch does not instantiate HomeKit or start a server. Explicitly choose **Load homes** to request Apple Home access. Login startup is a separate user opt-in through Apple's Service Management; no package downloads or external launcher are used.
- Default policy is read-only. With no selected home, only home names/UUIDs can be discovered. After selection, exactly one home and explicitly allowed accessory UUIDs are visible. New devices never join the allowlist automatically.
- Metadata writes require a saved opt-in policy and exact UUIDs. Renaming a room additionally requires that room UUID in the editable-room allowlist. Requests carry expected old names/room UUIDs and an idempotency UUID.
- The server saves a private pre-change journal before accepting a mutation. It returns `pending` immediately and verifies read-back before `succeeded`. An error or differing read-back is `unconfirmed`, blocks subsequent writes, and must be inspected. There is no automatic retry or false timeout-as-failure.
- Completed request identities survive restart. Unresolved journals prevent restarting in write mode. Read-only inspection remains available. After inspecting current inventory, manually archive reviewed records to a private directory before enabling writes again. Do not delete a pending journal to make an uncertain operation disappear.
- Stop closes the actual listener/connections and rejects queued, unaccepted writes. Previously accepted HomeKit operations may still complete. Their journal remains authoritative; stopping is not a rollback.

## Build and test

Requirements: macOS 13+, Python 3.9+, and Xcode with Mac Catalyst SDK/support installed. No third-party application dependencies. The app embeds its own small AppKit bundle for the status menu; both targets are built from this repository and signed by the same team.

```sh
make test
make build-unsigned
```

Tests compile the **same dispatcher/transport source files** used by the application. The fixture executable does not import HomeKit and cannot access real devices. CI also builds the actual application; build failures are required failures, not ignored signing warnings.

An unsigned build is for validation. For actual HomeKit use, build in Xcode with your own Apple development team and suitable provisioning, or run `make build-signed DEVELOPMENT_TEAM=YOUR_TEAM_ID`. In Xcode, assign the same team to the app and HomeKitMenu targets. This does not enable automatic provisioning updates or accept account agreements. Never reuse the upstream author's team identity. Inspect the signed bundle and nested menu signatures before granting access. Apple's login-item API also requires a code-signed app.

For initial provisioning, select your team in the app target's **Signing & Capabilities → All** pane so Xcode can enable HomeKit on the iOS App ID and generate its Mac Catalyst profile too. HomeKit on the Mac requires Mac Catalyst; the app target must not also declare a native macOS destination. The menu bundle is a separate native macOS target. Do not remove the HomeKit entitlement to silence a provisioning failure. Keep profiles/private keys local; source control contains no team identity. Development certificates/profiles expire, so check their expiry before relying on unattended operation.

## First connection

1. Build and sign the native app. Open `HomeKitMCP.app` yourself.
2. Choose **Load homes** and grant the system HomeKit permission if you want this app to access your home.
3. Select the intended home and check the accessories that may be inventoried/maintained. **Select all current accessories** chooses the loaded inventory as a fixed UUID list; it never authorizes future devices automatically. Leave metadata writes off initially. Save selection.
4. Choose **Start bridge**. Running requires both successful HomeKit inventory and socket setup.
5. Inspect with the CLI:

```sh
python3 scripts/homekitctl.py accessories
python3 scripts/homekitctl.py rooms
```

For MCP, configure a local stdio server whose command is `/usr/bin/python3` and arguments are the absolute path to `scripts/homekitctl.py`, followed by `stdio`. The native app must already be running. The relay never launches it or requests HomeKit permission on your behalf. Protocol output is stdout; diagnostic errors are stderr. No bearer token or network port is needed.

Policy is in `~/Library/Application Support/HomeKitMCP/policy.json`; journals are in its `journal/` subdirectory. Policy changes take effect after Stop/Start. The current running policy is immutable.

## Background operation

Move the signed app to a stable location such as `~/Applications/HomeKitMCP.app` before enabling **Open at login**. The house icon in the macOS menu bar offers Settings, Start read-only bridge, Stop, login settings, status files and Quit. Closing the configuration window keeps the app and socket alive. If the window was closed, Settings creates it again. If the embedded menu cannot load, the app does not start an unattended bridge.

**Open at login** uses `SMAppService.mainApp`, for this Mac user only. If macOS requires approval, allow the app in System Settings → General → Login Items. Disabling it there is respected; the app does not re-register it automatically. This is login startup, not a daemon or crash supervisor: the Mac must be awake and the user signed in, and a crash requires reopening the app or logging in again.

After a successful manual Start, a subsequent app/login launch may resume **read-only access only**, even if the saved policy permits metadata writes. It retains the same home/accessory allowlists and never expands them. **Stop** persists a pause across launches and logins; **Quit** closes this process while preserving the last resume intent. Returning to write mode always requires an explicit foreground Start. On first installation or without a saved home selection, no HomeKit manager or socket is created automatically.

The private `runtime.json` stores resume intent. `status.json` records phase, mode, timestamp and PID; `status-journal.json` keeps at most 128 phase changes. Neither status file records home/room/accessory names, UUIDs or native error details. A process lock prevents another instance overwriting their state. After a crash the files are historical until the next launch; check the live socket before assuming availability. The separate operation journal still contains the required private pre-change snapshots.

Every 30 seconds the running bridge checks access to the selected home. A temporary HomeKit outage keeps the local socket available, reports `home_unavailable`, and returns to `running` after HomeKit recovers. This checks the HomeKit inventory API, not the physical reachability of every accessory. It never retries metadata mutations.

## Tools

Read-only: `get_all_accessories`, `get_all_rooms`, `get_operation`. Initial unconfigured bootstrap only: `list_homes`.

Opt-in metadata writes: `set_accessory_room`, `rename_accessory`, `rename_room`. All use `home_uuid`, a fresh `request_uuid`, target UUIDs, and expected old values. Read `tools/list` for the complete required JSON schemas. Repeating an identical request UUID returns the original operation; reusing it for different arguments is rejected. Query `get_operation` until an outcome is known. A `pending` result means accepted, not completed.

`serial_number` is optional and is not read through deprecated HomeKit characteristics on Mac Catalyst. Use stable Apple Home accessory UUIDs and explicitly reviewed mappings to HA entities. Names are never used to locate mutation targets.

## Reviewable room plans

Create a desired JSON list of `{ "accessory_uuid": "...", "room_uuid": "..." }`, using the UUIDs from fresh allowed inventory. The source of that mapping can be a reviewed HA-area mapping; this helper never reads HA credentials, executes `hass-cli`, or guesses targets by name.

```sh
python3 scripts/manage_homekit_rooms.py plan --desired desired.json --output private-artifacts/plan.json
python3 scripts/manage_homekit_rooms.py apply --plan private-artifacts/plan.json --plan-sha256 HASH_PRINTED_BY_PLAN --output-directory private-artifacts/results
```

Review the plan before applying its hash. Every row is checked against fresh inventory before the first write; duplicate semantic UUIDs and drift are rejected. A private pre-change snapshot is saved before any mutation. Each operation is verified and a pending/unconfirmed outcome stops the batch. There is no automatic bulk rollback: use the saved snapshot to construct a new inverse mapping, review it, and apply a fresh plan. Missing accessories or changed names/rooms require reconciliation, not an automatic override.

## Compatibility and security scope

The upstream HTTP endpoints, name-based commands, actuator tools, automatic startup, plaintext env-file workflow and post-change-only snapshots are intentionally removed. Update existing clients to the stdio relay.

See [SECURITY.md](SECURITY.md) for the threat model and remaining validation boundaries. No public HomeKit endpoint is part of this architecture.
