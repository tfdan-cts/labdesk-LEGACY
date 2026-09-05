---
type: plan
created: 2026-09-05
status: active
supersedes: nothing
related:
  - docs/plans/2026-09-03-001-feat-labnet-overlay-plan.md
  - docs/plans/2026-09-04-002-rmm-decisions.md
  - docs/plans/2026-09-04-003-rmm-architecture.md
---

# LabDesk production program

The owner's order on 2026-09-04, late evening: proceed without pause until LabDesk is a fully
updated, fully functional, feature rich, production ready application in accordance with what was
discussed and planned, with a stable and hardened installer, an iOS companion app, and the fixes
that stop browsers and operating systems treating the downloads as malware. Every phase runs as a
gauntlet loop (builder plus a blind critic per piece, looping until the critic picks ours), with
the verifier named before the work starts, tests written before the code where the change has a
testable seam, and the documentation updated in the same commit as the change.

This file is the program's source of truth. When a phase closes, its row here changes in the same
commit that closes it. The session ledger is the vault's `development-log.md`.

## Rules the program runs under

- Nothing is reported done without a measurement: a CI run id, a test log, a probe output, a
  screenshot, or a log line from a real machine. Reading code is not verification.
- Rust is proven by CI and by field checks on real machines. Cargo cannot build this crate on the
  development workstation.
- The field test of labnet is the owner's, on dan_zenbook and trapLab-Foundry, with the real
  applications and Tailscale stopped on Foundry. Agents do not stop Tailscale, do not install on
  zenbook, and do not seed accounts in production.
- Two things are owner-only and are prepared here, never claimed: a code-signing certificate
  (Windows Authenticode, OV or EV; Apple Developer ID for macOS) and an Apple Developer account
  for the iOS app. No client-side change removes SmartScreen or the browser download warning on an
  unsigned binary. The pipeline is built so both turn on the moment the secrets exist.
- The plan of record for the RMM is the 21 work packages in `2026-09-04-003-rmm-architecture.md`
  section 9. A phase below names which packages it closes. Nothing is built that section 10 of that
  plan says is deliberately not built.
- Master moves only by a release pull request the owner merges. `dev` on the site is the deploy
  branch and is merged by the program when a phase's Worker changes pass their critic.

## Phases

| Phase | Closes | Verifier (named before the work) | Status |
|---|---|---|---|
| 0. labnet stage 1 assembled | Access bypass for `/agent/*` and `/console/*`, app-token actor, the human plane mounted under `/console` for the desktop, machine-plane signing over IPC, enrolment and netbird control from the privileged daemon, `/org` page, migrations 0002..0009 applied, broker merged to `dev` | Worker suite and tsc; cargo test in CI; `flutter test test/labdesk_*.dart`; production probes answer JSON not 302; a build published and installed on Foundry | Built, deployed. Closed 2026-09-05: site `35389e2` = `dev`, deployed by the first passing dev build (`c255ed62`, deployment `91ca5aa3`); migrations applied; `/agent` and `/console` on the bypass, both answering JSON 401 unsigned; client `d9d9b23dc` (Full Flutter CI 33947923067 Dart job green, CI 33947922842 green) built as release `labnet-ready` by run 33948273476 (x86_64 Windows installer SHA-256 `bd0c263a...f41dd`, aarch64 Windows and iOS jobs failed) and installed on Foundry 07:04Z. Field test with the owner is 0b. |
| 0b. labnet field test | The owner's exit criterion: one session over the overlay address from the console, then the fall-through | zenbook log `labnet: direct path to 1935956186` at a NetBird address; Foundry listener log on its NetBird address; Tailscale service stopped on Foundry during the run | Waits on the owner (UAC on zenbook, sign-in on both consoles). Prepared 2026-09-05: the `labnet-ready` build is on Foundry with Tailscale untouched and nothing enrolled, and the owner's step list, every label and log line read from source at `d9d9b23dc`, is at the session scratchpad `gauntlet-evidence/field/ready/README.md`. No signed-in console has reached `/console` in production yet; a 302 or non-JSON answer there is the first thing to report. |
| 1. RMM completion | WP10 disk platform on real hardware, WP13 tool catalog and jobs, WP15 connect tickets, WP16 address book, WP17 web console pages, WP18 Flutter console fed from the server, WP19 Linux delivery, network view per adapter, self-heal console switch, technician presets, labnet stage 2 surfaces | Each package's verifier from section 9, run by the critic in a fresh checkout; field checks on Foundry and homebox for disk and Linux delivery | In progress. Flutter console (WP18, network view, self-heal switch, presets, labnet stage 2 surfaces): the PTY metrics probe deleted, health read from lab-desk.net, the per-adapter view and the self-heal switch built, ready-made automation rules added, and the labnet create-with-fleet, rename and fresh-sign-in retry closed. What it had to differ on is section 13 of `docs/plans/2026-09-05-002-phase1-contracts.md`. |
| 2. Installer, signing, iOS | WP20 update signing turned on end to end with a real key ceremony; Authenticode signing step live on secret; MSI and installer hardening; the iOS application built in CI, tested in the simulator, TestFlight ceremony documented | A signed build measured on a clean Windows machine (SmartScreen state recorded, not inferred); an ipa built by CI; simulator test log | Not started. Certificate and Apple account are owner-only. |
| 2b. Public launch | Cloudflare zone hardening pass (WAF custom rules, rate limiting, bot and scraping protection, probe defence, TLS and header posture) with every setting read back from the live zone; the admin section brought to the Safe Sight admin portal's standard (reference: ~/TrapLab/safe-sight-app) with a registration switch: on means new accounts are usable at once, off means new sign-ups land pending and are listed for approval in admin; then the private-phase Access wall comes down and the site is public. The wall's removal deletes every CF_ACCESS_TOKEN dependency (build sync and runtime allowlist code). | Live zone settings and rulesets read back over the API after the change; probes from outside the tenant; sign-up with the switch off lands pending and cannot sign in until approved; blind critic against the Safe Sight admin portal | Closed 2026-09-05, three pieces through two critic rounds each, evidence under the session scratchpad `gauntlet-evidence/zone/round-1`, `round-2` (each with `critic/`), `gauntlet-evidence/admin/round-1`, `round-2`, `critic-round-1`, `critic-round-2`, and `gauntlet-evidence/open/round-1`, `round-1-critic`, `round-2`. Zone: five custom rules, the one rate limit, the Free Managed Ruleset executed explicitly, strict SSL, hotlink protection, leaked credential checks, DNSSEC (DS pending at the registrar), AI bot policies with the managed robots.txt, all read back live (`zone/round-2/after-zone-readback.json`), recorded in the vault note `30_Projects/LabDesk/cloudflare-zone-hardening-2026-09-05.md`; site `b224af2` adds Permissions-Policy and `public/_headers`. Admin: site `60160dd` and `42fa3ff`, registration switch default off (`setting` table, migration `0010`), pending queue with approve and refuse, disable and enable, overview with a computed verdict, organizations, machines by reachability and open labnet sessions on a 15 s poll; the blind critic picked ours against the Safe Sight portal in round 2 (`admin/round-2/parity.md`). Open: site `81c74f8` = `dev`, live version `8d05fb5c`; Access wall `38db8dbf` and bypass `1af5bad9` deleted, `sync-access.mjs`, `access.ts`, the `CF_*` vars and the `CF_ACCESS_TOKEN` secret gone, `/api/setup/*` JSON 404 off localhost; a real production sign-up under the off switch landed pending, could not sign in, and was refused from the roster (`open/round-2/notes.txt`). The `/console` prefix stays because the shipped client speaks it. Owner leftovers: the inert `CF_ACCESS_TOKEN` on both build triggers, the preview trigger's plain `BETTER_AUTH_SECRET`, and the `ai_search` block, which costs AI answer-engine referrals (switch recorded in the zone note). |
| 3. Check the work | A fresh pass over every phase's claims: each verifier rerun from a clean checkout, each field claim rechecked on the machine, every document read against the code it describes | The rerun logs, with any claim that no longer holds reopened as a piece | Not started. Ordered by the owner 2026-09-05. |
| 4. Review and optimize | Runtime and code review of both repositories: hot paths measured before and after, dead code removed, the collector's and the console's resource use measured on Foundry and homebox, the Worker's write volume checked against the architecture's arithmetic | Measurements before and after, in the evidence directory; tests green | Not started. Ordered by the owner 2026-09-05. |
| 5. Release readiness | Security review of both repos, CHANGELOG, docs current, release pull request to master prepared | Review findings closed with tests; `gh pr view` of the release PR | Not started. Merge is owner-only. |

## Cloudflare access for the program

The Cloudflare API MCP plugin in this environment authenticates as the owner's account and reaches
account-level Access, zone settings, rulesets, DNS and Workers. It is the tool for every Cloudflare
change in phase 2b, and the deploy-phase finding that the production build trigger's
`CF_ACCESS_TOKEN` answers 401 stops mattering once the wall and its allowlist code are gone.

## Owner-only items, in the order they block

1. Code-signing certificate for Windows (OV or EV). EV clears SmartScreen from the first signed
   build; OV needs weeks of download reputation. Apple Developer ID for macOS builds.
2. Apple Developer account for the iOS application (TestFlight and App Store distribution).
3. The labnet field test on zenbook and Foundry (phase 0b).
4. Merge of the release pull request into master.

## Owner decisions, 2026-09-05

- Registration switch: OFF means sign-up still works but a new account lands pending, cannot sign
  in until an admin approves it, and admin opens on the pending list; ON means a new account is
  usable at once. Default OFF. (Owner: go with the recommended solution.)
- The desktop console's human plane: a `/console/*` prefix carries the app-token routes the
  desktop needs (the same handlers and the same `actor()` as `/api/org/*` and `/api/overlay/*`),
  and `lab-desk.net/console` goes on the bypass application as one entry like `/agent`. The
  bypass never gains `/api/*`. The prefix exists for the private phase and goes with the wall.
  Outcome 2026-09-05: the wall is gone and the prefix stayed, because the `labnet-ready` build
  speaks it; it goes when a client that speaks `/api` ships.
  Outcome 2026-09-05: the wall is gone and the prefix stayed, because the `labnet-ready` build
  speaks it; it goes when a client that speaks `/api` ships.

## Decisions taken by the program without the owner, flagged for review

- The iOS companion app is scoped as the existing iOS client target rebranded and carrying the
  server profiles, the fleet list with the same three state reachability, and the health board
  read from lab-desk.net. Remote control from the phone stays what the inherited client provides.
  No plan document described the iOS app before this file; if a different scope was meant, this
  row changes.
