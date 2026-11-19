#!/bin/bash
set -euo pipefail
DEST=/home/rosvend/backups
STAMP=$(date +%F)
mkdir -p "$DEST"

# Pi-hole: safe to archive while running
tar -czf "$DEST/pihole-$STAMP.tar.gz" -C /home/rosvend/homelab/pihole etc-pihole

# Jellyfin: stop for a few seconds so its database is consistent
trap 'docker start jellyfin >/dev/null' EXIT
docker stop jellyfin >/dev/null
tar -czf "$DEST/jellyfin-$STAMP.tar.gz" -C /home/rosvend/homelab/jellyfin config

chown -R rosvend:rosvend "$DEST"
find "$DEST" -name '*.tar.gz' -mtime +7 -delete
