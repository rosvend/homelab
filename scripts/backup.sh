#!/bin/bash
set -euo pipefail
DEST=/home/rosvend/backups
STAMP=$(date +%F)
mkdir -p "$DEST"

# Pi-hole: safe to archive while running
tar -czf "$DEST/pihole-$STAMP.tar.gz" -C /home/rosvend/homelab/pihole etc-pihole

# Jellyfin and ZeroClaw: stop for a few seconds so their SQLite databases are consistent
ZC="systemctl --user -M rosvend@ --quiet"
trap 'docker start jellyfin >/dev/null; $ZC start zeroclaw' EXIT
docker stop jellyfin >/dev/null
tar -czf "$DEST/jellyfin-$STAMP.tar.gz" -C /home/rosvend/homelab/jellyfin config

# ZeroClaw: config (encrypted keys + .secret_key) and data (WhatsApp session, memory, chats); owner-only
$ZC stop zeroclaw
(umask 077; tar -czf "$DEST/zeroclaw-$STAMP.tar.gz" -C /home/rosvend --exclude='.zeroclaw/data/sessions-broken-*' .zeroclaw)

chown -R rosvend:rosvend "$DEST"
find "$DEST" -name '*.tar.gz' -mtime +7 -delete
