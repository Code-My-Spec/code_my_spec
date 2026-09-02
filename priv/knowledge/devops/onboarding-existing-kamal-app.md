# Onboarding an Existing Kamal App onto CodeMySpec

Playbook for bringing an app that **already deploys with Kamal** (its own
config, its own service name, real deploy history) under CodeMySpec's own
provisioning pipeline (`Provisioning.run_step/3`, the generated `bin/deploy`,
`Deploy.run/3`). This is a different situation from `mix cms.new`, where
nothing exists yet and there is no prior deploy to collide with.

Built from the first real run of this: MarketMySpec, onboarded 2026-09-01.
Everything here was manually discovered or manually fixed once — the point of
this doc is that the next app (broken-oaths, or anything after it) shouldn't
have to discover it again.

---

## 0. Pre-flight — check these before touching anything

Do this first. Every item here is something that surfaced mid-cutover on
MarketMySpec and would have been cheaper to know in advance.

- **SSH onto the box and look for a legacy kamal service.** `ls .kamal/apps/`
  and `docker exec kamal-proxy kamal-proxy list`. If either shows an entry for
  this app under a *different* service name than what CodeMySpec's generated
  `config/deploy.yml` will use, read §3 before doing anything else — this is
  the one that causes real downtime if it's discovered instead of anticipated.
- **Check the box's registry binding.** `curl localhost:5000` from inside the
  box. If it's connection-refused but the box's private IP on 5000 answers
  (401 is fine — that means it's reachable, just needs auth), the registry
  container is bound to the private IP only, not loopback. Use the real
  private IP in `config/deploy.yml`'s `registry.server`, not whatever a
  credential-lookup helper reports — `localhost:5000` is a plausible-looking
  wrong answer, not an error.
- **Check prod's and uat's Hetzner network zones.** If they're in different
  zones (one `ash`, one `nbg1`, etc.), the platform's zone-aware network
  provisioning handles this automatically now, but it's worth knowing going
  in rather than being surprised by two networks appearing.

---

## 1. App-repo changes (one-time, committed to the app's own repo)

- **`config/runtime.exs`** — add an *additive* branch: skip the app's own
  legacy secrets-fetch (SSM, Vault, whatever it already does) when
  `DATABASE_URL` is already present in the environment, so a sops-decrypted
  boot doesn't fight with it. Leave the existing boot path alone otherwise —
  this is a fallback, not a replacement.
- **`Dockerfile`** — merge sops support into the app's existing Dockerfile
  rather than keeping a separate CodeMySpec-specific variant:
  - install `sops`
  - `COPY envs/*.enc.env` into the image
  - CMD → the new boot script (next item)
  - add `LABEL service="<kamal-service-name>"` **by hand**. Kamal's own
    `kamal build push` injects this label itself, but CodeMySpec's harness
    builds the image directly (never runs `kamal build`), so without this
    label `validate_image` fails the pull with "missing the 'service'
    label."
- **`rel/overlays/bin/boot`** (new) — release-overlay boot script: decrypts
  `envs/<env>.enc.env` with `SOPS_AGE_KEY` at container start, then execs the
  release. This is what the Dockerfile's CMD actually runs.
- **`rel/overlays/bin/migrate`** (existing file, modify) — add a branch: if
  `SOPS_AGE_KEY` is set, decrypt and exec the migration through sops;
  otherwise fall back to the app's existing migration path unchanged. Same
  additive shape as the `runtime.exs` change.
- **`.gitignore`** — a typical `/envs/*.env` ignore rule also matches
  `*.enc.env`. Add `!/envs/*.enc.env` or the encrypted files can't be
  committed at all.
- **Health endpoint** — add `/health` alongside whatever the app already uses
  (`/up`, etc.) to match CodeMySpec's deploy-readiness convention.

## 2. `config/deploy.yml` / `config/deploy.uat.yml`

CodeMySpec's generator produces these, but an app with real history often has
its own hand-tuned version already. Reconcile:

- **`registry.server`** — the box's private IP (see §0), not `localhost`.
- **`registry.username` / `registry.password`** — env refs
  (`[KAMAL_REGISTRY_USERNAME]` / `[KAMAL_REGISTRY_PASSWORD]`), not a
  hardcoded value from an old setup.
- **`ssh:` block** — needs `keys_only: true` and an explicit
  `keys: [ "<%= ENV["CMS_SSH_KEY_PATH"] %>" ]`. A bare `ssh: user: root` with
  no keys reference falls back to interactive password auth, which dies with
  `ENOTTY` the moment it runs inside the non-interactive builder.
- **`env.secret`** — must list `SOPS_AGE_KEY` itself, not just the app's own
  secrets. `bin/deploy`'s `migrate()` passes the key explicitly via `-e`, but
  `swap()`'s `kamal deploy` only forwards what's declared here — without this
  line the booted container has no key and can't decrypt its own env file.
- **`.kamal/secrets-common`** — needs `KAMAL_REGISTRY_USERNAME=${KAMAL_REGISTRY_USERNAME}`
  and `SOPS_AGE_KEY=${SOPS_AGE_KEY}` added alongside whatever the app already
  has there.

As of this writing, the generator itself already gets `--config-file` (not
the nonexistent `--config`) and `swap()`'s `--skip-push` right — those were
bugs found and fixed in `lib/code_my_spec/generators/deploy_artifacts.ex`
during MarketMySpec's onboarding, so a freshly-generated `bin/deploy` should
not need either fix again. Verify against the generator's current output
rather than assuming a hand-patched `bin/deploy` from an older onboarding is
still needed verbatim.

## 3. The legacy service-name collision (read this before your first real deploy)

**This is the one likely to recur** on any app already running kamal under
its own name/config, which includes broken-oaths.

What happens: if the app was ever deployed via kamal under a service name
different from what CodeMySpec's config generates (MarketMySpec's uat was
`market-my-spec-web-uat` from an old ghcr.io-based setup; the new config
generates plain `market-my-spec`), kamal's own bookkeeping
(`.kamal/apps/<old-name>/`) and kamal-proxy's route table are keyed by the
*old* name — invisible to a deploy running under the new one.

The first deploy attempt under the new config will boot fine and pass its own
health check, then fail at the very last step:

```
ERROR (SSHKit::Command::Failed): docker exit status: 1
docker stderr: Error: host settings conflict with another service
```

The new container is stopped cleanly by kamal itself when this happens — no
orphan left running, and the old service keeps serving traffic exactly as
before. **This failure mode is safe by default.** It only becomes
live-traffic-affecting once you act on it:

1. Confirm the collision is real: `docker exec kamal-proxy kamal-proxy list`
   on the box, looking for a same-domain entry under the old name.
2. **Get explicit human sign-off before retiring the old registration.** This
   is not something either an agent or an operator should decide alone —
   it's the actual go-live moment for the domain, not an infra cleanup step.
3. Once approved: `docker exec kamal-proxy kamal-proxy remove <old-service-name>`
   on the box. Leave the old container itself running (don't `docker stop`
   it) as a fallback in case the new deploy also fails — only the *route* needs
   to go.
4. **Retry the deploy immediately after removing the route**, not on a
   delay — the domain is unroutable between the removal and the new deploy's
   swap. MarketMySpec's uat was down for real for a few minutes doing this the
   right way (retried right away); doing it standalone with no retry queued
   would make that window arbitrarily long.
5. Verify with a direct `curl` against the domain afterward, not just the
   deploy's own reported status.

If the new deploy's `app:boot` step also fails after removing the route
(a bad migration, a bootstrap failure, anything), the domain stays down until
someone fixes it and retries — there is no automatic fallback to the old
service once its route is gone. Know this going in, and have the fix ready
before pulling the trigger on step 3.

## 4. Infrastructure gotchas (platform-side, already fixed, worth knowing about)

These were real bugs, fixed in CodeMySpec's own provisioning code during
MarketMySpec's onboarding — listed here so a *symptom* that looks like one of
these is recognized fast, not re-diagnosed from scratch.

- **Cross-zone prod/uat**: if an app's prod and uat boxes sit in different
  Hetzner network zones, provisioning now creates one private network per
  zone (each with its own non-overlapping CIDR) rather than assuming one
  shared network fits both. Should be transparent now; a `networks_overlap`
  or zone-mismatch error means this regressed.
- **Crash-consistent builder snapshots**: an ARM builder snapshot taken before
  disk writes are flushed can come back with every gemspec reading as
  `NilClass instead of Gem::Specification`. Fixed by running `sync` before
  `create_image`. If this exact symptom reappears, the snapshot itself is
  corrupt — delete it and let the next build re-bootstrap.
- **First deploy to a host with no kamal history at all**: `kamal app exec`
  (what `migrate` runs) needs a host env file that kamal only ever writes as
  a side effect of booting a container — so a host that's never had a
  successful deploy has nothing for migrate to read, and migrate fails before
  the migration itself runs. `Deploy.run/3` now detects this live and runs a
  one-time bootstrap boot before retrying migrate, logged as its own phase.
  This is unrelated to §3's collision — it's what happens on a host with
  nothing serving at all, not a host with something serving under a
  different name.

## 5. Process notes

- **Verify on the box, not just through the status page.** SSH in and check
  `docker ps`, `kamal-proxy list`, and curl the domain directly. Every one of
  tonight's real findings came from ground truth on the box, not from a
  status report — `devops_status`'s own error-truncation logic went through
  several rounds of bugs (head-only, then tail-only, then head+tail that
  still missed content sitting in the middle) during this exact onboarding.
  Sanity-check that a status message is actually complete before trusting it
  on a new or rare failure shape.
- **`run_provisioning_step({step: "deploy"})` has no per-environment scope.**
  It always runs prod, then uat, in one call. A uat-only retry still
  re-exercises prod's entire build/push/migrate/swap sequence first — usually
  fast, occasionally slow. Budget for this when estimating how long a retry
  cycle takes; it is not a bug, just a current limitation worth knowing about
  when planning a cutover window.
