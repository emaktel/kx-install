# Kamailio Edge (DB-less) with PostgREST-driven Routing

**What it does**
- Kamailio listens on UDP/5060 and allowlists your carrier IPs/CIDRs
- For INVITEs, it uses `mtree` to map called number → `f1` / `f2`
- A systemd-timed helper calls **PostgREST** and writes `/etc/kamailio/dest.map`, then hot-reloads

## Install

```bash
sudo apt update && sudo apt install git -y && cd ~ && git clone https://github.com/emaktel/kx-install.git kamailio-edge
cp .env.example .env
# edit .env (F1_HOST/F2_HOST, CARRIER_SOURCES, POSTGREST_* values)
chmod +x scripts/install.sh && ./scripts/install.sh
```

## Logs

```bash
journalctl -u kamailio -e -n 100
journalctl -u pull-routing.service -e -n 50
head /etc/kamailio/dest.map
```

## PostgREST endpoint

**Auth**: `Authorization: Bearer ${POSTGREST_KEY}`

Default expects a **VIEW** as follows:

```sql
CREATE OR REPLACE VIEW public.edge_export_routing_view AS
SELECT DISTINCT
  ('+' ||
     regexp_replace(vd.destination_prefix, '\D', '', 'g') ||
     regexp_replace(vd.destination_number,  '\D', '', 'g')
  )::text                         AS num,
  vdms.server_affinity::text      AS target
FROM public.v_destinations vd
JOIN public.v_domains vdms
  ON vd.domain_uuid = vdms.domain_uuid
WHERE vdms.domain_enabled IS TRUE
  AND lower(coalesce(vd.destination_enabled, '')) = 'true'
  AND vd.destination_type = 'inbound'
  AND vd.destination_prefix IS NOT NULL AND vd.destination_prefix <> ''
  AND vd.destination_number  IS NOT NULL AND vd.destination_number  <> ''
  AND vdms.server_affinity IN ('f1','f2')
ORDER BY num;
```

Returning:

```json
[
    {
    "num": "<E164 or normalized>",
    "target": "f1|f2" },
    ...
    }
]
```

## Change routing

* Flip tenant affinity in `v_domains.server_affinity`
* Add/remove DIDs in `v_destinations`
* The timer (default every 2 min) updates `/etc/kamailio/dest.map` and hot-reloads mtree

## Notes

* CIDR allowlist needs `ipops` (installed via `kamailio-extra-modules`)
* If you want TCP/TLS to f1/f2, change the `$du` in the template to `;transport=tcp` or TLS

## Uninstall

```bash
sudo ./scripts/uninstall.sh
```

---

## Answers to your questions

- **"In the .env example where is the Postgres username/password set?"**  
  With PostgREST, you don't put DB creds on the Kamailio host. You call your **PostgREST** URL using `POSTGREST_KEY` (via `Authorization: Bearer <key>` or `apikey: <key>`), so the Kamailio box never talks to Postgres directly.

- **"Can we use PostgREST with curl instead?"**  
  Yes—this repo does exactly that. The helper calls `POSTGREST_RO_DB_URL + POSTGREST_EXPORT_PATH` with your `POSTGREST_KEY`, converts the JSON to `"<number> <f1|f2>"` lines, writes `/etc/kamailio/dest.map`, and hot-reloads Kamailio.
