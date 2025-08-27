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
sudo ./scripts/install.sh
```

## Logs

```bash
journalctl -u kamailio -e -n 100
journalctl -u pull-routing.service -e -n 50
head /etc/kamailio/dest.map
```

## PostgREST endpoint

Create an **RPC** that joins `v_destinations` to `v_domains.server_affinity`:

```sql
create or replace function public.edge_export_routing()
returns table(num text, target text)
language sql
stable
as $$
  select
    case
      when vd.destination_number like '+%' then regexp_replace(vd.destination_number,'[^+0-9]','','g')
      else regexp_replace(vd.destination_number,'\\D','','g')
    end as num,
    vdms.server_affinity::text as target
  from public.v_destinations vd
  join public.v_domains vdms using (domain_uuid)
  where vd.destination_enabled = 'true'
    and vd.destination_number is not null
    and vd.destination_number <> ''
$$;
```

After deploying the function, the helper posts to:

```
POST {POSTGREST_RO_DB_URL}/rpc/edge_export_routing
Headers:
  {POSTGREST_AUTH_HEADER}: [optional {POSTGREST_AUTH_SCHEME}] {POSTGREST_KEY}
Body: {}
```

The function must return JSON like:

```json
[{"num":"+15145550001","target":"f1"}, {"num":"+15146660002","target":"f2"}]
```

Prefer an RPC for reliability. If you expose a view instead, set `POSTGREST_EXPORT_PATH` to `/edge_export_routing_view` and the helper will still work (change the method in `bin/pull-routing.sh` to `GET` if needed).

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