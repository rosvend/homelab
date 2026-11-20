# Pi 5 WhatsApp shopping agent: architecture and phased plan

## Context
You want a personal agent you can message on WhatsApp. It should browse, compare prices, book, handle email, and spend real money with Colombian cards. It runs on a 4 GB Pi 5 that already hosts Tailscale, Jellyfin and Pi-hole. There is no local LLM, and Chromium should not run on the Pi.

There is no open-source "agent wallet", so the plan combines an existing runtime with a small payment gate that you own. The model must never be the thing that authorises money. `../paygent` already uses this rule ("the gateway decides every spend, never the model"), and its code is reused here.

**Design rules (from your feedback):**
1. **Transport-agnostic.** No component assumes Tailscale. The approval/web surface binds to `127.0.0.1:<port>` and takes a single `PUBLIC_BASE_URL`. That URL can come from `tailscale serve` (your setup), a Cloudflare Tunnel, ngrok, or Caddy/nginx with Let's Encrypt.
2. **Loosely coupled.** Every replaceable part sits behind a small interface (§3a), so switching from Browser Use to Steel, or from ZeroClaw to NanoClaw, is a config change plus one adapter.

Research for this plan was done remotely with `gh api`, docs and image manifests, because plan mode forbids clones. Phase 0 clones the repos and measures RAM on the real Pi.

---

## 1. Resource budget (measured 2026-11-19 over SSH)
| | RAM |
|---|---|
| Total | 4049 MB (+2 GB swap, on the SD card) |
| Used now (Jellyfin RSS 340 MB, dockerd 99, containerd 56, tailscaled 53, pihole-FTL 29, OS) | ~590 MB |
| **Available** | **~3.46 GB** |
| Jellyfin software-transcoding spike (Pi 5 has no hardware encoder) | +0.8–1.5 GB (estimate) |
| **Proposed agent stack** | |
| ZeroClaw runtime (Rust, single binary) | 30–80 MB (estimate, to be measured in Phase 0) |
| `shopper` MCP service (Python + browser-use + Playwright client; browser runs in the cloud) | 200–300 MB while active |
| `payexec` (Python + Playwright client, idle except during payments) | 80–150 MB |
| **Agent peak total** | **~350–550 MB** |
| Worst case (agent peak + Jellyfin transcoding) | ~2.6 GB used, ~1.4 GB headroom ✅ |

Findings that affect the plan:
- `docker stats` shows `0B`, which means the **memory cgroup is disabled**. Any `mem_limit` would silently do nothing. Fix: add `cgroup_enable=memory` to `/boot/firmware/cmdline.txt` and reboot. Use systemd `MemoryMax=` for the native services.
- The root filesystem is on the SD card, so put agent SQLite and logs on low-write paths. A USB SSD is optional.
- Running local Chromium (~250–400 MB, plus 100–300 MB per heavy tab) would fit, but a home IP with an ARM fingerprint gets flagged by Amazon, MercadoLibre and airline sites. That is the real reason to use a cloud browser, more than RAM.

## 2. Component comparison
### Agent runtime
| | **ZeroClaw** ✅ | PicoClaw | NanoClaw | OpenBot |
|---|---|---|---|---|
| Lang / ARM64 | Rust; aarch64 binary plus arm64 image | Go; arm64 binary/.deb/image | TS/Node + Docker; build it yourself | TS + Postgres/K8s; Mac DMG only |
| RAM | tens of MB (estimate) | 10–20 MB | 0.5–1 GB+ | GBs ❌ |
| WhatsApp | built in: linked device (`whatsapp_web.rs`) + Cloud API | whatsmeow only with a custom `-tags whatsapp_native` build | Baileys + Cloud API skills | **none** ❌ |
| MCP | yes | yes | yes | yes |
| Blocking approval | **built in over WhatsApp** (`approval_gate.rs`, fails closed) | hook; you write the WhatsApp part | credential actions only | web UI |
| Sandbox | Landlock/Bubblewrap/Docker | regex deny-list | container per agent (best) | containers |
| Secrets | ChaCha20 store; **successful tool output reaches the model unredacted** | model keys only | credential gateway | vault |
| Maintenance | v0.9.0 on 11-12, very active | last release 07-03, slowing | daily release candidates | active |

### Browser layer
| | RAM on Pi | Cost | Persistent login | Fit |
|---|---|---|---|---|
| **Browser Use Cloud + browser-use lib** ✅ | client only | $0.06/h + $5/GB proxy, CAPTCHA included | cloud profiles | best price; exposes a CDP URL for `payexec` |
| Steel Cloud | client only | $0.10/h, CAPTCHA $3 per 1k | profiles + Credentials API (beta) | good fallback |
| Steel self-hosted | Chromium on the Pi | ~0 | userDataDir | ports have no auth; home-IP bot flags |
| browsercode | Bun ~150–300 MB | — | via BU Cloud | it's a *coding* agent (OpenCode fork) with telemetry on by default; wrong fit for chat |
| Browserbase / Anchor / Hyperbrowser | client only | $20–50/mo floor | contexts | pricier, nothing extra we need |
| Lightpanda | small | 0 | weak | breaks on real checkouts ❌ |

### Secrets / auth
| | Fit |
|---|---|
| **SOPS + age** ✅ | One Go binary, arm64. Stores the card and the few site passwords, encrypted at rest. Only the `payexec` Unix user can decrypt. |
| OneCLI | Injects HTTP headers via a MITM proxy, so it **cannot fill form fields**. 7 containers plus Postgres. Skip for now. |
| Infisical Agent Vault | In preview, needs about 4 GB (Postgres + Redis). Too heavy for this Pi. |
| `bw` CLI | Its session key unlocks the whole vault. Keep it off the agent host. |
| `bws` | Fine later for API keys. |
| Agent-payment protocols (Visa Agentic Ready, Mastercard Agent Pay, AP2, ACP) | None usable in Colombia today (Visa CO consumer use reportedly 2027). We copy AP2's *mandate* idea instead. |

## 3. End-to-end architecture
```
 You (main phone) ──WhatsApp──► agent number (linked device)
                                     │
 ┌──────────── Pi 5 ─────────────────┼──────────────────────────────────┐
 │  user: agent                      ▼                                   │
 │  ┌──────────────────────────────────────────┐   LLM API (external)    │
 │  │ ZeroClaw (systemd, MemoryMax=256M)        │◄──────────────────────► │
 │  │  WhatsApp channel · SQLite memory · cron  │                         │
 │  │  MCP ─► shopper  ─► email-ro              │                         │
 │  └──────────┬───────────────────────────────┘                         │
 │             │ MCP (stdio)                                             │
 │  ┌──────────▼──────────┐  CDP (wss)   ┌──────────────────────────┐   │
 │  │ shopper (Python)     │─────────────►│ Browser Use Cloud browser│   │
 │  │ browse / compare /   │              │ per-site persistent      │   │
 │  │ build cart           │              │ profile (pre-logged-in)  │   │
 │  │ request_payment(...) │              └───────────▲──────────────┘   │
 │  └──────────┬──────────┘                          │ CDP (exclusive    │
 │             │ unix socket (only path to money)     │  during payment)  │
 │  ───────────┼──── user boundary ───────────────────┼───────────────    │
 │  user: payexec                                     │                   │
 │  ┌──────────▼────────────────────────────────────────┐               │
 │  │ payexec (deterministic, no LLM)                    │               │
 │  │ policy: allowlist, caps, velocity (paygent rules)  │               │
 │  │ tx → canonical JSON → H=sha256 → nonce, exp 10m    │               │
 │  │ SOPS/age: card + OTP regex; age key 0400 payexec   │               │
 │  │ Gmail readonly (OTP only, sender allowlist)        │               │
 │  └──────────┬─────────────────────────────────────────┘               │
 │             │ approval page via `tailscale serve` (https://pi.*.ts.net)│
 └─────────────┼─────────────────────────────────────────────────────────┘
               ▼
   You: WhatsApp message "Pay $X to merchant Y — approve: <tailnet link>"
        Phase 1: page shows tx and asks for PIN · Phase 2: same page, WebAuthn passkey (challenge = H)
```
The diagram shows your deployment: Tailscale transport, Browser Use, ZeroClaw. Every box is replaceable as described below.

### 3a. Seams (ports and adapters)
Each seam is one small interface; adapters are picked by config (`agent/config.yaml`). Only add a second adapter when it's actually needed (YAGNI), except where noted.

| Seam | Interface (minimal) | Default adapter | Drop-in alternatives |
|---|---|---|---|
| **Agent runtime** | Talks to our services only over MCP (stdio/HTTP) + `notify(text)` | ZeroClaw | **NanoClaw (your fork)**, PicoClaw, OpenClaw: anything that speaks MCP. `shopper` and `payexec` know nothing about the runtime. |
| **Chat channel** | owned by the runtime | ZeroClaw `whatsapp_web` | NanoClaw Baileys skill, WhatsApp Cloud API, Telegram |
| **Browser provider** | `BrowserProvider.open(profile) -> cdp_ws_url`, `.close(id)` | `BrowserUseCloud` | `SteelCloud`, `SteelSelfHosted`, `LocalChromium`. All produce a CDP URL, and everything after that is plain Playwright/browser-use over CDP, so the provider is the only code that changes. |
| **Browsing brain** | MCP tools `search_compare`, `inspect_product`, `screenshot`, `request_payment` | `browser-use` lib | Stagehand, raw Playwright scripts |
| **Secret store** | `SecretStore.get(handle) -> value` (payexec only) | `SopsAge` | `BitwardenSM (bws)`, env (tests) |
| **Approver** | `Approver.challenge(tx) -> page data`, `.verify(tx, proof) -> bool` | `PinApprover` | `WebAuthnApprover` (Phase 2) |
| **OTP source** | `OtpSource.wait(sender_allowlist, regex, timeout) -> code` | `GmailReadonly` | IMAP (himalaya), manual entry on the approval page |
| **PSP fill adapter** | `PaymentForm.detect(page) / .fill(page, card)` | MercadoPago, Amazon saved-card | one per new checkout type |
| **Transport (ingress)** | none in code: `PUBLIC_BASE_URL` + bind `127.0.0.1` | `tailscale serve` | Cloudflare Tunnel, Caddy/nginx + TLS, ngrok |

The interfaces between processes are the stable contracts:
- MCP between the runtime and `shopper`;
- a JSON-over-unix-socket between `shopper` and `payexec`;
- HTTPS between you and the approval page.

Each of the three processes can be rewritten or replaced independently.

**Approval page over a public tunnel** (users without a VPN). It's internet-reachable, so it gets hardened in code, not just at the network edge:
- unguessable one-time path token (128-bit, per tx, expires in 10 min);
- PIN with an argon2 hash, a lockout after 3 failures that freezes payments, and rate limiting;
- WebAuthn RP ID derived from `PUBLIC_BASE_URL` (works on any HTTPS origin, since WebAuthn only requires TLS and a stable domain);
- strict CSP and no third-party assets;
- optional Cloudflare Access/OAuth in front.

With Tailscale these become defence in depth; with a public tunnel they're required.

Flow:
1. A WhatsApp command reaches ZeroClaw, which calls the `shopper` tools.
2. `shopper` drives the cloud browser with its saved logins, compares prices, and builds the cart.
3. The agent calls `request_payment({merchant_domain, amount, currency, cart_summary, card_handle})`.
4. `payexec` checks its policy and builds the tx. It sends you the approval link on WhatsApp through ZeroClaw. Only the link passes through the agent; approval itself never does.
5. You approve on the tailnet page.
6. `payexec` takes exclusive CDP control and re-checks the top-level origin and the total shown on the page. It fills the card (and any email OTP) itself, clicks Pay, and reads the confirmation.
7. It returns only `{status, order_id}` to the agent.

## 4. Threat model and payment safety
| Threat | Control |
|---|---|
| Prompt injection on a product page or review triggers a purchase | The agent can't pay. `request_payment` only *proposes*. `payexec` refuses without a fresh human approval bound to `H`. |
| Injection changes the amount or merchant after you approve | `H` covers domain, amount, cart_hash and card. `payexec` re-reads the page origin and total right before clicking and aborts on any mismatch. The nonce is single-use and expires in 10 min. |
| Agent forges an approval | Approval arrives over HTTPS on the tailnet, straight to `payexec`, protected by a PIN (Phase 1) or a passkey (Phase 2). The agent process can't reach that endpoint's secret, and a reply in the WhatsApp chat is never accepted as approval. |
| Card or password leaks into the prompt or logs | SOPS files and the age key belong to the `payexec` user (0400). The agent only sees handles (`card:nu-temp`). Playwright traces and screenshots are off during fills. Logs store handles and hashes only. |
| Agent reads what `payexec` typed into the page | `payexec` holds CDP exclusively while paying (the agent's session is paused) and hands it back afterwards. Saved cards on the site mean only the CVV is typed. |
| OTP or inbox exfiltration | Gmail `readonly` scope is used by `payexec`, not the agent. Sender plus regex allowlist; the code goes into the page, and the LLM only sees "OTP filled: yes". The agent's email tool is read-only and filtered, and sending is drafts only in Phase 1. |
| Agent sends WhatsApp messages to strangers (data exfiltration) | Allowlist of outbound recipients. A new contact, such as a restaurant, needs approval through ZeroClaw's `approval_gate` (medium risk). |
| Runaway spend | `payexec` caps per transaction, per day and per merchant (port `../paygent/src/agents/guardian/rules.py`). Bank-side cap: a Nu 24-hour temporary virtual card or a low-limit top-up debit pocket. Bank alerts go to your phone. |
| Third-party cloud browser sees payment pages | Accepted risk for Phase 1. Mitigated by a low-limit or temporary card and by deleting recordings. Fallback: run only the `payexec` step on a local Chromium (fits in RAM). |
| WhatsApp bans the agent number (unofficial linked-device API) | Use the dedicated number, as you planned. Keep message volume human-like. Switching to Cloud API later is a ZeroClaw config change. |
| Approval page exposed through a public tunnel | One-time path token, PIN lockout that freezes payments, rate limit, CSP, optional Access/OAuth (§3a). A WebAuthn passkey is phishing-resistant because it's bound to the origin. |
| Pi compromise | Services bind only to 127.0.0.1; reachable only through the chosen tunnel or proxy. Separate Unix users, systemd hardening (`ProtectSystem=strict`, `NoNewPrivileges`). |

**Phase 1 to Phase 2:** the approval page and the `tx`/`H`/nonce design stay the same. Only the verifier changes:
- Phase 1: PIN (argon2 hash) plus single-use nonce.
- Phase 2: WebAuthn assertion with `challenge = H` and `userVerification: "required"` (py_webauthn 3.x, RP ID = MagicDNS name). The signature then covers the exact transaction.

The verifier sits behind one small interface, `Approver.verify(tx, proof) -> bool`, so the upgrade is a new class and no other code changes.

## 5. Phased roadmap (TDD throughout; tests first for all `payexec` logic)
**Phase 0: verify and prepare (about 1 day)**
1. Clone zeroclaw, picoclaw, steel-browser, browsercode, onecli and sops into `../` (they're for reading; the homelab directory stays clean).
2. Install the ZeroClaw aarch64 binary on the Pi and measure idle and active RSS while running a WhatsApp QR link with a test number. Check that `approval_gate` timeout and recipient allowlist can be configured.
   - Re-test the bugs your NanoClaw fork already fixed (`rosvend/nanoclaw`: `senderPn` fallback for LID JIDs, the `getMessage` callback for "Waiting for this message", LID mentions in groups) against ZeroClaw's `whatsapp-rust`.
   - Check that it can send an image (screenshot) to WhatsApp.
   - **Decision gate:** if ZeroClaw fails these tests, use NanoClaw (your fork, rebased on upstream, 2514 commits behind) as the runtime. Nothing else changes, because of the MCP seam. The cost is ~0.5–1 GB more RAM, which still fits.
3. Enable the memory cgroup (`cmdline.txt`) and reboot. Check that `docker stats` shows real numbers.
4. Create a Browser Use Cloud account. Use the live view to log in once manually to MercadoLibre CO, Amazon and one bus/flight site. Check whether profile persistence survives 7 days and whether a CO residential proxy is available.

**Phase 1a: chat and read-only browsing**
5. Add `homelab/agent/` with:
   - `zeroclaw.toml` in `supervised` mode, WhatsApp linked device, sender allowlist = your number;
   - `agent.service` (systemd, user `agent`, `MemoryMax=256M`);
   - `README.md`.
6. Add `homelab/agent/shopper/`: a Python MCP server using `browser-use` against a CDP URL from `BrowserProvider`. Tools: `search_compare(query, sites)`, `inspect_product(url)`, and `screenshot(url|current)` (CDP `Page.captureScreenshot`, sent as an image over WhatsApp; disabled while `payexec` holds the session). Read-only, with no checkout tools.
   - Build two `BrowserProvider` adapters from the start, BrowserUseCloud and LocalChromium. The second is a cheap test double and proves the seam works.
   - Contract test: the same tests pass against both providers.
7. Email: Gmail API `readonly` MCP tool for the agent (filtered labels), drafts only.
8. Extend `scripts/backup.sh` to cover `agent/` state (SQLite memory, encrypted SOPS files only).

**Phase 1b: payments with WhatsApp/PIN approval**
9. Add `homelab/agent/payexec/` (Python, user `payexec`). Write tests first for:
   - canonical tx + `H` (port `canonicalize` from `../paygent/src/shared/src/crypto.ts`);
   - policy rules (port the `guardian/rules.py` patterns): domain allowlist, caps, velocity;
   - nonce single-use and expiry;
   - page total/origin mismatch → abort.
10. `payexec` approval page bound to `127.0.0.1`, reached at `PUBLIC_BASE_URL`, with PIN verification through `Approver`.
   - Document two ingress recipes in `agent/README.md`: `tailscale serve` (yours) and a Cloudflare Tunnel (public, plus the hardening in §3a).
   - Tests cover the token, lockout and rate-limit paths.
11. Per-PSP fill adapters (MercadoPago iframe, Amazon saved card plus CVV, one airline/bus PSP), each tested against saved HTML fixtures.
12. `shopper.request_payment` → unix socket to `payexec`.
13. First real purchase: a cheap MercadoLibre item on a Nu 24-hour temporary card.

**Phase 1c: conversational extras**
14. Restaurant and booking chats through ZeroClaw WhatsApp outbound, with each new recipient approved.
15. Price-watch cron jobs that report back over WhatsApp.

**Phase 2: biometric approval**
16. Add a `WebAuthnApprover` (py_webauthn) with RP ID taken from `PUBLIC_BASE_URL`. Register a passkey from your phone through whichever ingress you use, then switch the config. Keep PIN only as a break-glass option.

Later, only if needed: a `SteelCloud` provider adapter (one class, plus the contract tests in step 6).

## Verification
- Phase 0: SSH RSS numbers recorded in `agent/README.md`, and `docker stats` showing non-zero memory.
- `payexec`: `pytest` covers the policy, nonce, H-binding and mismatch-abort paths, including an injection fixture where the page total ≠ the approved amount → abort.
- End to end:
  - WhatsApp "find cheapest X on MercadoLibre" returns a comparison.
  - "Buy it" sends an approval link. Approving with a wrong PIN, letting it expire, or approving with a changed amount is refused.
  - A correct approval leads to the order ID being reported back.
  - `grep` over agent logs and SQLite for the PAN, CVV or passwords returns nothing.
- Memory watch: `free -m` while Jellyfin is transcoding and the agent is paying stays above 1 GB available.

## Critical files
- New: `agent/config.yaml` (adapter selection, `PUBLIC_BASE_URL`), `agent/zeroclaw.toml`, `agent/*.service`, `agent/shopper/`, `agent/payexec/` (+ `tests/`), `agent/secrets/*.sops.yaml`, `.sops.yaml`
- Modified: `scripts/backup.sh`, `README.md`
- Reused: `../paygent/src/shared/src/crypto.ts` (`canonicalize`, Ed25519 helpers), `../paygent/src/agents/guardian/rules.py` (deterministic spend rules)
