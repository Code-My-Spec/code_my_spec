# Shared Phoenix host

One Hetzner CX32 running many Phoenix release apps, isolated from each other.
No Docker, no orchestrator. Optimised for low operational surface and for
later liftability into SOPS + Terraform — **not** for HA.

Story 986. The acceptance criterion is `verify_isolation.sh`, not the
provisioning: the build is incomplete until every one of its checks fails as
expected on a breached box. `provision_app.sh` sets up one app; `harden_host.sh`
sets up the box everything shares — the tenant-boundary protections that have
no per-app home.

## Shape

| Concern  | Choice                                              |
| -------- | --------------------------------------------------- |
| Ingress  | Caddy, the only public process. One block per app.   |
| Apps     | Mix releases. One systemd unit, one port each.       |
| Database | One Postgres. One database + one role per app.       |
| Secrets  | SOPS + age. One key per app, plus the admin key.     |
| Deploy   | Build tarball → `scp` → `systemctl restart appN`.    |

## Dev and prod are the same behaviour

The scripts here *are* the behaviour. Where they run is configuration:

| | target | how |
| --- | --- | --- |
| dev | a Docker container | `Environments.Container`, local daemon |
| prod | a Hetzner box | same environment, `DOCKER_HOST=ssh://user@box` |

`CodeMySpec.Host` runs them through `Environments.cmd/4` either way and never
branches on which. That means the scripts rehearsed in `./drill.sh` are
byte-for-byte the ones that run on the box — a drill that exercised a
different code path would be reassurance rather than evidence.

```sh
./drill.sh    # provision two apps in Docker, then breach each isolation check
```

## Host setup, once

```sh
apt-get install -y postgresql caddy age
# sops is not packaged — take the release binary
curl -sSL -o /usr/local/bin/sops \
  https://github.com/getsops/sops/releases/latest/download/sops-linux-amd64
chmod +x /usr/local/bin/sops

# Caddy loads per-app blocks from here; provision_app.sh writes into it. The
# global block moves the admin API off its default TCP port (127.0.0.1:2019,
# which every tenant can reach and use to rewrite all routing) onto a unix
# socket in a caddy-owned 0750 dir. RuntimeDirectory creates /run/caddy at boot;
# without it caddy cannot bind the socket.
mkdir -p /etc/caddy/sites
printf '{\n\tadmin unix//run/caddy/admin.sock\n}\n\nimport /etc/caddy/sites/*.caddy\n' \
  > /etc/caddy/Caddyfile
mkdir -p /etc/systemd/system/caddy.service.d
printf '[Service]\nRuntimeDirectory=caddy\nRuntimeDirectoryMode=0750\n' \
  > /etc/systemd/system/caddy.service.d/runtime-dir.conf

# iptables for the app-port firewall (harden_host.sh); iptables-persistent so
# its rules and the hidepid /proc mount survive a reboot.
apt-get install -y iptables iptables-persistent

# Once, after the packages are in place: hidepid on /proc, the app-port
# firewall, and the caddy socket dir. Idempotent — re-run whenever it drifts.
./harden_host.sh

# Swap. ~80–120 MB idle per BEAM release means 8 GB holds roughly twenty small
# apps plus Postgres, and swap is what turns "one app over budget" into slow
# rather than into the OOM killer picking a victim.
fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

### Postgres connections

Default Ecto `pool_size: 10` against `max_connections: 100` breaks at ten
apps, and it breaks as "database unavailable" on whichever app happens to
start last — nowhere near the cause.

Set `pool_size: 2` (3 for anything busy) in each app's `runtime.exs`, and keep
the total under `max_connections` with room to spare: `psql` itself needs a
slot, and so does whatever you use to debug the problem.

## Per app

```sh
export ADMIN_AGE_PUBKEY=age1...        # yours, not the box's
./provision_app.sh app1 4001 app1.example.com
```

Idempotent — safe to re-run after a partial failure, which is the run most
likely to have one.

Then put the release in `/opt/app1` and `systemctl start app1`.

### What it does

1. Unix user `app1`, home `/opt/app1` mode 750, no login shell
2. age keypair at `/etc/app1/age.key`, mode 400, owned by the app
3. Secrets encrypted to **two** recipients — the app's key and the admin key
4. Postgres role + database owned by that role
5. `REVOKE CONNECT ... FROM PUBLIC`, then grant to the owner only
6. systemd unit, hardened, running the release under `sops exec-env`
7. Caddy block, validated before reload

## Verify

```sh
./verify_isolation.sh app1 app2
```

Each check asserts a **failure** — that `app1` *cannot* reach something of
`app2`'s:

1. its age key (file mode)
2. its home dir listing (`/opt` mode)
3. its database (`REVOKE CONNECT`)
4. its BEAM node over distribution (epmd / cookie)
5. its process argv, which carries the distribution cookie (`/proc` hidepid)
6. its Caddy admin API and its app port directly (socket dir mode + firewall)

It confirms the positive case first — that `app1` really can reach its *own*
key and database — because otherwise it would pass on a box where nothing is
installed. Checks 5 and 6 need a running `app2`; they skip, rather than falsely
pass, when it is not up.

Exits non-zero on any failure, so it can gate a deploy rather than being read
by a human who may or may not be looking. `breach_host.sh app1 app2` proves the
host-level checks (5, 6, and hidepid) actually fire, by breaching each and
confirming it is caught — `drill.sh` does the same for checks 1–3.

## Three things that bite

**BEAM distribution cookies — the highest-severity item here.** All apps share
one epmd. If one app's cookie is known to another node, that node gets
`:erpc`: arbitrary code execution as that user. Set
`RELEASE_DISTRIBUTION=none` in `rel/env.sh.eex` for every app that does not
need clustering (the unit template does this too, but the release-level
setting is the one that survives someone editing the unit). Apps that *do*
cluster need a unique cookie each — not a shared one.

**`REVOKE CONNECT` is not optional.** Postgres grants CONNECT to PUBLIC on
every new database, so skipping step 5 means every app role reaches every
app's data. Isolation here is off by default and nothing warns you.

**Restarts are a 2–5 second outage.** LiveView clients reconnect on their own
and users see a reconnect flash rather than an error, which is acceptable at
this tier. If one app outgrows it, run two units for that app and let Caddy
round-robin between them. Do not introduce an orchestrator — that is the
decision this whole design is making.

## Backups

Required, not optional:

```
0 3 * * * postgres pg_dumpall | gzip | ssh -p23 uXXXXX@uXXXXX.your-storagebox.de "cat > dump-$(date +\%F).sql.gz"
```

A dump nobody has restored is a file, not a backup. Restore one into a scratch
database before you rely on it.

## Pen-tested

Three agents attacked a running two-app host, each acting as the `app1` Unix
user against `app2` — one on filesystem/secrets, one on database/network, one
on BEAM/process/privilege. The core boundaries held:

- **Secrets** — the age key (400), the ciphertext (640, and app1 is not a
  recipient), `/proc/<pid>/environ` (owner-only), `/tmp` (`PrivateTmp`), and
  journald (group-gated) all held. app1's key mathematically cannot decrypt
  app2's file.
- **Database** — `REVOKE CONNECT` held across TCP, the unix socket, the app's
  own connection pool, privilege-escalation attempts, and superuser
  impersonation. `pg_authid`/`pg_shadow` refused; no `trust` in `pg_hba`.
- **Distribution** — `RELEASE_DISTRIBUTION=none` means no node name and no
  listener, so `:erpc` RCE is closed *even with the correct cookie in hand*.

It found three real cross-tenant reaches, **all now fixed and each guarded by a
check that fails on regression** (`verify_isolation.sh` 4–6, `breach_host.sh`):

- **Caddy admin API (critical).** Its default endpoint, `127.0.0.1:2019`, is
  unauthenticated and localhost is not a boundary between tenants: as `app1` an
  agent read every app's routing and `POST /load`'d the whole ingress down.
  Moved onto `/run/caddy/admin.sock` in a `0750 caddy:caddy` dir — root and
  caddy reach it (graceful `caddy reload` still works), tenants cannot.
- **Distribution cookie via argv.** A release boots with `-setcookie` on its
  command line, so the cookie sits in world-readable `/proc/<pid>/cmdline` —
  defeating the locked-down `COOKIE` file. `hidepid=2` on `/proc` hides other
  tenants' process entries entirely.
- **Cross-tenant app port.** Both apps bound `0.0.0.0`; `app1` hit `app2`'s
  Phoenix port directly, bypassing Caddy's TLS and routing. An owner-matched
  firewall lets only root and caddy open the app-port band on loopback.

Two earlier items also fixed: `/opt/appN` was 755 (a `cp -a` deploy widens 750
back — provisioning re-asserts it, check 2 catches it), and `releases/COOKIE`
was world-readable (now 640). All host-level fixes live in `harden_host.sh`.

## Out of scope

Metrics, log aggregation (`journalctl -u appN` is the interface), HA,
multi-node, containers, CI beyond producing a release tarball.
