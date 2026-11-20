# ZeroClaw agent ("onix")

Personal AI agent reachable over WhatsApp, running natively on the Pi 5 as a systemd user service.
Architecture and roadmap: [docs/agent-architecture.md](../docs/agent-architecture.md).

## Prerequisites
Enable the memory cgroup so `MemoryMax` is enforced: append ` cgroup_enable=memory` to the single line in `/boot/firmware/cmdline.txt`, then reboot.
Check it with `cat /sys/fs/cgroup/cgroup.controllers`, which should list `memory`.

## Install (v0.9.0, pinned and checksum-verified)
```sh
d=$(mktemp -d) && cd "$d"
base=https://github.com/zeroclaw-labs/zeroclaw/releases/download/v0.9.0
f=zeroclaw-aarch64-unknown-linux-gnu.tar.gz
curl -fsSLO $base/$f && curl -fsSLO $base/SHA256SUMS
grep " $f\$" SHA256SUMS | sha256sum -c - && tar -xzf $f
install -m 0755 zeroclaw ~/.local/bin/zeroclaw
mkdir -p ~/.local/share/zeroclaw/web/dist && cp -r web/dist/. ~/.local/share/zeroclaw/web/dist/
```

## Configure
1. Run `zeroclaw quickstart --model-provider anthropic --model claude-sonnet-5-5` in an interactive SSH session (it needs a TTY). It asks for the API key and stores it encrypted.
2. Merge [config.example.toml](config.example.toml) into `~/.zeroclaw/config.toml`, using your own number in `external_peers`.
3. Run `zeroclaw channel start`, then scan the QR code from the agent phone (WhatsApp → Linked devices). Press Ctrl+C once it's linked.

## Run as a service
```sh
zeroclaw service install
loginctl enable-linger "$USER"     # keep running after logout / start at boot
mkdir -p ~/.config/systemd/user/zeroclaw.service.d
cp systemd/memory.conf ~/.config/systemd/user/zeroclaw.service.d/
systemctl --user daemon-reload && systemctl --user enable --now zeroclaw
```
Logs:
- `journalctl --user -u zeroclaw -f`
- events: `~/.zeroclaw/data/state/runtime-trace.jsonl`

## Measured (Pi 5, 4 GB)
- Daemon RSS: about 55 MB with WhatsApp connected and idle.
- Reply latency: about 2 s.

## Known issues (v0.9.0)
- **`channel list` says WhatsApp is "not compiled".** This is a false alarm: the check only looks at the Cloud API feature. WhatsApp Web works.
- **"the selected model provider rejected the request".** This is upstream [#12401](https://github.com/zeroclaw-labs/zeroclaw/issues/12401). It is worked around by turning thinking off.
  - If a chat is already stuck, stop the service and move `~/.zeroclaw/data/sessions/sessions.db*` aside.
- **The daily and monthly cost caps are not enforced.** Sonnet 5.5 has no built-in price, so add its rates under `[cost.rates]`.
- **`excluded_tools` under `[channels.whatsapp.*]` is ignored.** Use `[risk_profiles.<name>].excluded_tools` instead.
