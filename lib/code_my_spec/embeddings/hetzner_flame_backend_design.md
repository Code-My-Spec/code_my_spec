# A Hetzner-hosted FLAME burst box — design notes (577de9bb, step 7 follow-on)

**SUPERSEDED.** This file's own "two shapes John left open" question —
ephemeral-per-call vs. persistent-power-cycled — is resolved, and not in
either direction this file argued for. John's actual model, stated directly
in a later review of this work: one long-lived burst box *per environment*
(ours hosts our embeddings and our builds; a customer's hosts theirs),
checked near the end of its Hetzner billing hour and deleted only if idle —
not an ephemeral box per runner (what this file recommended) and not a
power-cycled on/off box either (this file's rejected alternative). See
`CodeMySpec.Provisioning.BurstBox.Lifecycle` and `.Sweep` for the actual
policy, and `CodeMySpec.Embeddings.HetznerFlameBackend`'s current moduledoc
for the reshaped backend. Everything below is kept for its still-accurate
research — the FLAME-internals reading (`handle_info/2` never firing for a
normal finish, `Terminator` dialing out rather than being dialed) does not
change — but its "recommendation" section and its billing-while-off question
are no longer the open question driving this.

Status: **groundwork only, not wired up, not provable against a real account
from this task.** Read `CodeMySpec.Embeddings.HetznerFlameBackend`'s own
moduledoc first — it documents the current gaps from the code's point of
view; this file is a comparison and recommendation from an earlier pass,
now superseded by the note above.

## Why this exists

Step 7 of the embeddings rework was originally scoped as "burst `EmbedPool`
onto Hetzner." That turned out to be two different pieces of very different
size:

- Routing `EmbedPool` through `FLAME.FlyBackend` in prod, since this app is
  already Fly-deployed — **done**, on `main`
  (`lib/code_my_spec_web/application.ex`, `embed_pool_backend/1`).
- A genuine **Hetzner-hosted** pool, as a second, cheaper compute option —
  this file and `CodeMySpec.Embeddings.HetznerFlameBackend`.

The two are unrelated in difficulty. Fly already has a portable image, a
private network between the parent and every runner, and a backend that ships
in the `flame` hex package. Hetzner has none of that for this app — the three
things below are all missing *before* the two burst-box shapes even become a
question.

## Three prerequisites, true regardless of which shape wins

1. **A portable artifact.** This app deploys to Fly via Fly's own remote
   builder, which publishes to `registry.fly.io` — not reachable from
   anywhere but a Fly machine. "We host our own registry, but a Docker image
   is also fine" (John) answers *how* the artifact travels, not where it's
   built or published from; that pipeline does not exist yet. The root
   `Dockerfile` already builds a production release image and is the obvious
   starting point, but a FLAME runner boots differently from the normal web
   release — `PHX_SERVER=false`, a `FLAME_PARENT` env var, no HTTP traffic —
   so at minimum this needs a build+push step producing the *same* image
   Fly's `release_command`/machines use, landing somewhere a Hetzner box can
   `docker pull` from.

2. **Erlang distribution across providers.** `FLAME.Terminator` dials out
   from the runner to the parent (`Node.connect(node(parent.pid))`,
   `deps/flame/lib/flame/terminator.ex`) — the runner initiates, which is the
   easier half. But `rel/env.sh.eex` only sets `RELEASE_DISTRIBUTION` for two
   cases: `FLY_APP_NAME` present (a long name on Fly's private 6PN network)
   or a short list of CLI commands (an `sname`, loopback-only). A Hetzner box
   has neither — it would fall into the `sname` branch today and could never
   connect to a different host at all. Making this work needs:
   - a new branch in `rel/env.sh.eex` for "booted as a FLAME runner, not on
     Fly" (a long name bound to whatever address the box actually has), and
   - a real network path from that box to the Fly-hosted parent. Hetzner's
     own private networking (`CodeMySpec.Provisioning.Hetzner.ensure_network/3`)
     only reaches other Hetzner boxes in the same project. Reaching a Fly
     machine needs either a Fly WireGuard peer into the box, or a publicly
     reachable, TLS-secured distribution listener on one side with a
     firewall rule narrow enough to not be a liability. Nothing here attempts
     either — it is a real decision with security consequences, not a config
     flag.

   Until both of these exist, `HetznerFlameBackend.remote_boot/1` can create
   a Hetzner server, but the box can never dial the parent back, and every
   boot times out. This is the single biggest open question in the whole
   effort and the one most worth a second opinion before investing further.

3. **Credentials reaching the box without leaking.** `user_data` (this
   task's first deliverable — see `CodeMySpec.Provisioning.Hetzner.create_server/3`)
   makes it *possible* to hand a box a cloud-init script, a registry login,
   and app env vars at creation. It does not answer which registry, what
   credential a bare box uses to pull a private image, or how long that
   credential lives. `Hetzner.create_server/3`'s own logging redacts
   `user_data` already (added in this task), but the API payload itself still
   carries whatever secret the script needs, readable by anyone who can read
   the server's own metadata via the account's API token — the same trust
   boundary the account's token already sits inside, but worth stating
   plainly rather than assuming.

## The two shapes John left open

### A. Ephemeral — create on boot, destroy when done

One Hetzner server per `FLAME.Runner`, created in `remote_boot/1`, matching
`FLAME.FlyBackend`'s own idiom: `max: N` reads as "up to N boxes in flight."
This is what `HetznerFlameBackend` implements.

**What's good about it:**
- Matches how FLAME's own pool semantics are written and documented — `min`/
  `max`/`idle_shutdown_after` all assume "booting a runner" means "getting
  fresh capacity," not "turning on a box that was already configured."
- No new Hetzner API surface needed beyond `user_data` (already built) —
  `create_server`/`delete_server` already exist.
- Nothing survives between bursts. A box that's wrong (bad image, stale
  cloud-init) is simply never reused; the next burst gets a clean one.

**What's not free, and was wrongly assumed to be free in an earlier pass of
this design:**
- **There is no Hetzner equivalent of Fly's `auto_destroy: true`.**
  `FLAME.FlyBackend` never needs to explicitly delete anything because Fly's
  own platform deletes a machine when its init process exits. Hetzner Cloud
  servers do not do this — a server whose OS halts just sits there, powered
  off, **still billing** (Hetzner's documented position is that a stopped
  Cloud Server still reserves its resources and bills at the same rate;
  verify this against Hetzner's current pricing page before relying on it,
  since this was not re-checked against the live API in this task).
- Worse: reading `deps/flame/lib/flame/runner.ex`'s own `handle_info/2`
  directly (not guessed) shows that **`FLAME.Backend.handle_info/2` — the
  hook this module's first draft assumed cleanup would use — is never called
  for either event that means "this runner is finished."** Both
  `{_ref, {:remote_shutdown, reason}}` and the terminator's own `:DOWN`
  message go straight to `{:stop, reason, state}` inside `Runner` itself,
  without ever calling `maybe_backend_handle_info/2`. A successful,
  long-lived runner that finishes normally currently has **no FLAME-provided
  hook at all** for this backend to destroy the box it created.
  `remote_boot/1`'s own boot-timeout path destroys the box fine (that's
  plain code, not a FLAME callback) — there is nothing equivalent for the
  success path.
- The fix is a separate piece of infrastructure, not a FLAME callback:
  either a periodic sweeper in the shape of
  `CodeMySpec.Provisioning.Builder.reap_orphaned_builders/2` (label the box,
  delete anything past an idle/age threshold — the `Builder` boundary
  already has this exact pattern for abandoned build boxes), or a
  self-destruct call issued *from the remote node itself* right before
  `system_shutdown/0` calls `System.stop()` — which means shipping the
  Hetzner API token to the burst box, a real tradeoff this file does not
  resolve.
- Boot latency: a Hetzner Cloud server plus a `docker pull` is almost
  certainly slower than a Fly Machine boot (`FLAME.FlyBackend` defaults to a
  30s timeout; this module defaults to 120s as a guess, not a measurement —
  nobody has booted one of these yet).

### B. Persistent, power-cycled — one server, turned off when idle

John's own framing: *"The burst box can sit there turned off... boot
everything when it's go time and then turn it off when done."* One (or a
small fixed number of) Hetzner server(s), created once, then powered off
between bursts and powered back on when `FLAME.Pool` needs capacity.

**What's good about it:**
- Skips the "no auto_destroy equivalent" problem above entirely — there's
  nothing to destroy, only to power off. A power-off API call is simpler and
  safer than a delete.
- Possibly faster to resume than a cold create+cloud-init+pull, if the image
  is already pulled and the container just needs starting — though this
  depends on whether a *stopped* Cloud Server's disk survives a power cycle
  with the pulled image intact (it should — Hetzner's power-off is a normal
  ACPI shutdown of a persistent disk, not a teardown), which would make
  resume meaningfully faster than ephemeral's cold boot.

**What it costs that the ephemeral shape doesn't:**
- **Hetzner has no power-on/power-off API wrapper in this codebase today.**
  `CodeMySpec.Provisioning.Hetzner` has no `poweron_server/2` / `poweroff_server/2`
  — real, new API surface, not a config flag.
- **The idle-cost assumption needs verification, not faith.** If a
  powered-off Hetzner Cloud server keeps billing at the same hourly rate (see
  the ephemeral section above — this is Hetzner's documented general
  position, re-confirm before committing), the entire premise of "turn it
  off to save money" does not hold the way it would on, say, a bare-metal
  auction server or a platform that genuinely stops billing a stopped
  instance. This needs a real check against Hetzner's current pricing
  terms before this shape is chosen *for the cost reason John gave* — if the
  cost argument doesn't hold, the remaining advantage is only latency.
- **Awkward fit with `FLAME.Pool`'s own `min`/`max` elasticity.** A pool's
  `max` describes how many runners can exist *concurrently*. One persistent,
  power-cycled box gives you `max: 1` in practice — true elasticity would
  need provisioning several persistent boxes up front, which multiplies the
  "still billing while off" cost by however many you provision, undermining
  the idle-savings argument further. FLAME's pool semantics assume
  `remote_boot/1` can always get *more* capacity by booting another runner;
  "power on the one box that already exists" doesn't compose with that the
  same way "create another one" does.
- **First-boot vs. resume is two code paths, not one.** The first time a
  given persistent box boots it needs the full cloud-init bootstrap
  (install Docker, pull the image, configure the container to restart);
  every boot after that just needs the box powered on and the already-
  configured container started — likely via a systemd unit or Docker's own
  restart policy set up on that first boot. `remote_boot/1` would need to
  tell these two cases apart (has this `runner_name`/label been created
  before?) and handle both, which `HetznerFlameBackend` does not attempt.

## Recommendation

**Build on the ephemeral shape — which is what `HetznerFlameBackend` does —
and treat the sweeper/self-destruct gap as the very next piece of work, not
an afterthought.** Reasoning:

- It needs zero new Hetzner API surface beyond `user_data` (built, tested,
  in this change).
- It matches FLAME's own pool model, which the codebase otherwise already
  trusts for the Fly backend.
- The persistent shape's main selling point — "turning it off saves money" —
  rests on a Hetzner billing assumption that was not verified here and may
  simply be false for Hetzner Cloud specifically (it is true for some other
  providers, which may be where the original framing came from). If that
  turns out to be false, ephemeral and persistent cost close to the same
  while persistent carries strictly more implementation complexity (new
  power API, first-boot/resume branching, worse elasticity fit).
- Ephemeral's own missing piece — a destroy hook, since FLAME provides none
  for a normal finish — is a bounded, well-precedented addition
  (`Builder.reap_orphaned_builders/2` is nearly the exact shape needed) and
  does not block anything else in the meantime: a leaked box costs money,
  not correctness, and `mix cms.provisioning_leaks` already exists as a
  blunt backstop pattern to extend.

This is not a close call being presented as one: persistent/power-cycled's
case rests on an unverified cost claim and adds real new surface
(power on/off, first-boot/resume branching) for a latency win that has not
been measured either way. If the billing-while-off assumption is confirmed
true and matters enough, it's worth revisiting — but that confirmation
should come before more code, not after.

## What would actually need to happen to prove this end-to-end

In order, and each one gates the next:

1. **Confirm or refute the Hetzner billing-while-off claim** against
   Hetzner's current pricing/ToS. Changes nothing about the ephemeral
   recommendation above but matters a lot if anyone revisits shape B.
2. **Decide and build the artifact pipeline** — which registry, how the
   existing `Dockerfile` (or a FLAME-specific variant) gets built and pushed
   there, and how a Hetzner box authenticates to pull it.
3. **Add the `rel/env.sh.eex` branch** for a non-Fly FLAME runner, and
   **decide the cross-provider networking story** (WireGuard peer into Fly's
   6PN is the most promising option, not yet attempted).
4. **Build the destroy mechanism** (sweeper, or self-destruct with the
   token question resolved) — can be built and tested independently of 2-3,
   entirely with `Req.Test`, same as this task's own unit tests.
5. **Wire `HetznerFlameBackend` into `lib/code_my_spec_web/application.ex`**
   behind a new `embed_pool_backend/1` clause, building the `:create_server`
   / `:destroy_server` closures there (where `CodeMySpec.Provisioning` is
   already a permitted dependency).
6. Only then: a real, human-run, `--include live`-tagged test against a real
   Hetzner account — boot one box, prove a function actually executes on it
   via `FLAME.call/3`, tear it down, confirm nothing is left on the invoice.
   **Nobody should run this except a human (or an explicitly-authorized
   follow-up) with the real `HETZNER_API_TOKEN`** — this task deliberately
   did not attempt it.
