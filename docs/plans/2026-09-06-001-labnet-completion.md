# Labnet completion and verification

The product requirement is built-in private networking, remote access and RMM between enrolled LabDesk machines. NetBird supplies WireGuard, NAT traversal and relay fallback; it is an implementation choice. Empty RustDesk server fields currently select RustDesk defaults and do not enroll a machine in labnet.

## Verified starting state

- Zenbook and Homebox have LabDesk 1.2.6 installed. Production has no enrolled machines, fleets, labnets or NetBird peers.
- A previous Homebox session used RustDesk discovery and LAN TCP. Neither that session nor a shared CGNAT address prefix proves labnet transport.
- The public NetBird server answers a valid UDP STUN transaction. Oracle administration through Homebox uses Tailscale and is not a product transport test.
- Forge and Foundry are unavailable until the owner announces otherwise.

## Implementation

1. Resolve per-machine NetBird group members through the real peer API. Validate the reported IP against that membership and restore approved standing labnet groups on reenrollment. Cover realistic API shapes, rejection and membership repair with Worker tests.
2. Deliver session tickets independently of telemetry. Acknowledge only after local ticket installation; wait for that target acknowledgment before dialing. Test authorization, expiration, retries and idempotency.
3. Restore an enabled machine's listener and identity from the always-running Rust server. Recover an installed but stopped owned service. Respect explicit disable and prevent slow commands from blocking indefinitely.
4. Reconcile desktop status and onboarding. Show preparation errors and direct versus relayed labnet state. Retain session grants for remote desktop, terminal, file transfer, camera and port forwarding windows.
5. Clarify the legacy RustDesk server settings so clearing them cannot be mistaken for labnet enrollment.

## Development ledger — 2026-09-06 stopping point

Implemented in `fix/netbird-completion`; not yet deployed or proven between real endpoints.

- Worker: resolves actual peer details from NetBird's peer API, validates a machine's reported overlay address against its own group, restores approved standing memberships, and acknowledges session tickets only after target IPC installation. Adds signed ticket polling and scoped controller readiness. Site commit: `fec8ee6b2a7fd99942f6d1d0e660275b8757682b`, pushed to the same branch name in `labdesk-site`.
- Rust: independent five-second ticket delivery, durable spent-ticket ledger before authentication, retry of failed claim reports, service-side listener reconciliation, strict management URL validation and bounded CLI/output waits. Owned NetBird configuration, state, logs, adapter and port prevent inheriting a separately installed NetBird client's settings. Managed connections bind the owned overlay source, bypass legacy SOCKS and stop on failed preparation/authentication instead of silently falling back.
- Flutter: organization/fleet enrollment with a real privileged-service probe, explicit enable/disable state, startup recovery, readiness deadline, visible preparation errors and explicit legacy fallback. All connection modes, including hidden RMM terminal sessions, use preparation and retain grants. Concurrent disable now wins over a delayed report.
- Build workflow: an artifact-only dispatch option gates all 16 release publishers plus the checksum publisher; Full Flutter CI explicitly disables publication. Windows x64 build now runs Labnet, overlay-address and ticket authentication unit checks. The workflow has not yet been dispatched with these changes.

Verification at this stopping point:

- 370 LabDesk Flutter tests passed. Full pinned Flutter analysis: 79 package issues, zero in the owned LabDesk paths.
- The Windows GUI built successfully using the matching previously built core DLL, so this verifies Dart/native GUI compilation, not the changed Rust core. A second incremental GUI build finished after the final lifecycle edits; its original tool call was interrupted, so a fresh captured build exit remains required before claiming that final artifact.
- Website TypeScript and production Vite build passed. The earlier 500-test serial run had one five-second timeout; both affected files subsequently passed all 74 tests with a 30-second deadline. A final complete run is being recorded separately in the handoff.
- 15 isolated Rust checks passed using the actual ticket module and extracted connection/reconciliation/process code, including durable replay rejection and a real inherited-pipe timeout regression. These are not a full crate or IPC test. Local full Rust compilation is blocked by missing libclang.
- Bundled NetBird 0.78.0 accepted the isolated seed configuration, generated its identity and reported Idle on the test pipe. The temporary process was stopped; no service installation or production network was changed.
- Rendered onboarding, Labnet On/error and fallback states were inspected. The actual changed legacy server-settings dialog and final installed build still require visual inspection.

No production migration, Worker deployment, machine enrollment, new service installation or release promotion was performed. Full native CI and real-device acceptance below remain open.

## Acceptance checks

- Focused regression tests fail on the old behavior and pass after each fix; complete required Flutter and Worker suites, analysis and platform build checks.
- Inspect actual rendered GUI changes and new installed artifacts; record screenshot/build identity.
- Enroll Zenbook and Homebox through the product flow, create a labnet, approve membership, verify assigned NetBird peer IDs, adapter/routes, ticket acknowledgment and remote access.
- Repeat with Tailscale disabled on both test endpoints. Record the actual socket destination and NetBird peer connection type. LAN success is separate from a cross-network NAT test.
- Exercise remote desktop and a long file transfer; confirm policy cleanup after close and listener recovery after restarting the agent.
- A direct UDP path is preferred; an authenticated NetBird relay path is a supported result when NAT/firewall conditions prevent direct connectivity. Never claim universal hole punching.
- Update durable project findings and retain explicit unverified items until their real checks run.

## Continuation review corrections

The full Rust review found `sign_here` using `Option<AgentIdentity>` as an identity; it now returns the existing not-enrolled error when absent. Durable ticket spends now go through one privileged IPC owner across desktop users and root/elevated callers; a per-user path or separate process caches of one path allowed duplicate spends. Authentication fails closed on service, persistence, or protocol failure, and the entire IPC request has a deadline. Inbox recovery backoff is capped at ten seconds within the thirty-second preparation window.

Fresh verification: 370 Flutter tests, pinned analysis with 79 inherited/zero owned-path issues, and a captured GUI build exit 0. Worker typecheck/build and500tests passed locally; site PR#2 checks passed and merged to dev at5b8d82a808c6f65db35ca8e5ebac71b91214ec84 after production0012 migration was applied/read back. Eleven isolated Rust checks passed on current source, covering concurrent machine spends, replay after restart, missing/unavailable service and persistence failure. Full native compilation and real-device acceptance remain pending; the GUI preview DLL is still the old core.

The continuation also reproduced a connection completing after disable during grant creation, target readiness, and option publication. Session and console generations now invalidate pending admission before shutdown. Local shutdown runs concurrently with remote grant cleanup, so an API outage cannot postpone it. The preparation deadline includes initial grant creation; a late minted grant remains owned and is released. Seven added regressions cover every option write and late creation. The complete Flutter suite passed 437 tests; pinned analysis remains at 79 inherited issues, zero in owned paths. Independent actual-class cancellation checks passed. General broker response deadlines are not changed by this patch.
