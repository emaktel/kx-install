# Kamailio Edge (DB-less) with Postgres-driven Routing

Debian 13 one-click install:
- Kamailio listens on UDP/5060
- IP-allowlists your carriers
- Forwards INVITEs to **f1**/**f2** based on an **mtree** file
- A helper pulls routing from **Postgres** (join of `v_destinations` × `v_domains.server_affinity`) and hot-reloads the map

## Quick start

git clone <your-repo-url> kamailio-edge
cd kamailio-edge
cp .env.example .env
# edit .env with your hosts, carriers, PGURL, etc.
sudo ./scripts/install.sh

Check logs:

```
journalctl -u kamailio -e -n 100
journalctl -u pull-routing.service -e -n 50
How it works
bin/pull-routing.sh exports rows as <number> <f1|f2> into /etc/kamailio/dest.map
```

Kamailio mtree matches by longest prefix and sets $du to f1/f2

The exporter runs on a systemd timer (default every 2 minutes) and attempts a hot-reload; if RPC isn’t available it restarts Kamailio as a fallback.

### Required Postgres shape
public.v_domains has domain_uuid uuid and server_affinity text CHECK ('f1'|'f2')

public.v_destinations has domain_uuid and destination_number (enabled rows used)

#### Uninstall
```
sudo ./scripts/uninstall.sh
This keeps the kamailio package installed but removes the systemd units and restores your previous /etc/kamailio/kamailio.cfg if a backup existed.
```

### How to use

1) Put these files in a new repo (exact structure above).  
2) `cp .env.example .env` and fill in `F1_HOST`, `F2_HOST`, `CARRIER_SOURCES`, `PGURL`, etc.  
3) `sudo ./scripts/install.sh` on your Debian 13 Kamailio VM.  
4) Flip `server_affinity` in Postgres (or change DIDs) → map refreshes automatically.