# DevOps spex: what makes them different

Most spex in this tree drive a page or a tool and assert on what comes back.
The devops ones provision real infrastructure on real provider accounts, and
that changes what "run the tests" means. This is the accumulated set of things
that cost someone a day, written down so it costs the next person an hour.

If you are about to record a cassette, read **Recording** first. If a spex
records green and replays red, read **Why a recording does not replay**.

---

## The shape of a devops spex

Four things happen that do not happen elsewhere:

1. **Real resources are created** — servers, DNS records, buckets, sending and
   receiving domains. On John's own accounts. They cost money and they change
   where mail and traffic go.
2. **Every spex must tear down what it made.** Teardown is registered up front
   with `teardown_later/3`, not written at the end of the scenario, so it runs
   even when the scenario fails halfway.
3. **Adopted resources are never torn down.** If a run finds a resource already
   there and adopts it, it does not own it and must not delete it. This is why
   residue from a crashed run is dangerous: the next run adopts it and the one
   after that inherits state nobody meant to keep.
4. **Everything goes through a cassette.** Replay must not touch the network,
   and recording must capture a run that genuinely proves the criterion.

## Sanctioned domains

Record against **astralbi.com**, **earwitness.app**, or **spex.astralbi.com**
and their subdomains. Never **codemyspec.com** — that is production.

Servers named **fuellytics** and **fuellytics-prod** are real and must never be
deleted. `mix cms.provisioning_leaks` knows the difference between those and
residue; run it after a recording session.

Each criterion gets **its own subdomain** (`c8030.astralbi.com`,
`c8033.astralbi.com`, …). Sharing one name across a story means whichever
criterion runs second adopts the first's domain, never tears it down, and every
run after that replays somebody else's state.

---

## Recording

    SPEX_CASSETTE_MODE=record mix spex --pattern "test/spex/974_*/criterion_8030_*_spex.exs"

Credentials come from the **dev database**, not from the environment. The spex
Case reads the live OAuth grant out of `code_my_spec_dev` and refreshes it under
the row lock. If a provider's grant is dead you get a placeholder that produces
401s, and only the spex that actually need that provider fail.

`envs/.env` is **not** in `System.get_env/1` — Dotenvy loads it into config.
Anything that reads the environment directly (`GITHUB_SPEX_OWNER`,
`HETZNER_API_TOKEN`) needs it exported first:

    set -a; source envs/.env; set +a

Recording is slow on purpose. `:provisioning_waits` is `:real` while recording
and `:none` on replay, so the sleeps that give a provider time to converge cost
nothing when replaying.

### Inbound mail: the MX has to be warm

The single biggest time sink in this directory.

The inbound teardown removes the MX it published. So the next recording
republishes it, and **mail does not route until that propagates** — longer than
the probe's poll window. A cold domain produces a recording of a message that
never arrived, which then replays as a cassette miss and reads like drift.

Six recordings went into learning this. The pattern that works:

1. Publish the MX out of band and leave it up (TTL 60).
2. Confirm it resolves — `dig +short MX <domain> @1.1.1.1`. The local resolver
   may still be negative-caching; that does not matter, AWS resolves publicly.
3. Record. A warm domain records in about 80 seconds; a cold one polls to
   exhaustion for 7-11 minutes and fails.

Two things that look like the cause and are not:

- **The local part.** `spex-probe@` and `user-<phash>@` both failed while
  `user-<int>@` succeeded, which suggests a routing rule keyed on the address.
  It is not: querying the mailbox afterwards showed zero arrivals for either,
  late or otherwise. They were never delivered, not delivered slowly.
- **A sending-only domain.** Resend grants `receiving` **only at creation** and
  never afterwards, so a domain registered sending-only is unrecoverable for an
  inbound criterion and drops every probe in silence. This is a real trap —
  `default_inbound_probe/3` documents it — but check before believing it: the
  Resend API reports the domain's capabilities directly.

---

## Why a recording does not replay

Cassettes are matched **sequentially**: one interaction consumed per request,
in order. So replay fails whenever the code issues a different sequence than
the recording captured. Three causes, in the order they actually happen:

### 1. Ambient state changed which branch the code took

The one that hides best. `Repository.ensure/3` calls `GET /user` only when no
`:owner` was supplied, and the Case supplies one from `GITHUB_SPEX_OWNER` —
which lives in `envs/.env` and is therefore present only if the recording
operator had it exported. Thirteen cassettes were recorded with it and ten
without, and the thirteen could not replay at all.

Now handled: `with_full_cassette` reads the owner back out of the cassette,
since that is the only durable record of the environment a recording was made
in. A cassette that carries `GET /user` is left alone — handing it an owner
would skip a recorded interaction.

**Symptom:** the miss is on the *first* request of a block. Method and URI both
green, nothing matched.

### 2. Something in the request is per-run

`received?/3` compares the inbound message's recipient exactly, and the probe
address is built from the user's email local part. With a fresh user per run,
the recording captured a message to `user-…403550@` and replay looked for
`user-…406782@`, never matched, and polled until the cassette ran dry.

Now handled: spex user emails are derived from the spex module, so they are the
same in both passes. Per file rather than constant, because one test that
registers two users would collide on the email index.

The same class bit the subject token before it, which is why the arriving
message is identified by id rather than by a token it carries.

**Symptom:** the poll runs to its limit and exhausts a cassette whose
interactions all look correct.

### 3. The code changed and the cassette did not

`already_received/2` was added ahead of the send, so the request order became
`receiving → domains → POST → receiving`. Cassettes recorded before it start
with `domains` and desynchronise immediately.

**Symptom:** method and URI match, but the interaction was already spent.
Compare the recorded order against what the code issues — that diff is the
answer.

---

## Two cassettes share one name

`with_full_cassette "foo"` writes **two files**:

| Path | Written by | Top-level keys |
|---|---|---|
| `test/cassettes/foo.json` | ReqCassette (HTTP) | `interactions`, `version` |
| `test/fixtures/cassettes/foo.json` | ExCliVcr (shell) | `commands`, `ports` |

Anything reading a cassette by name must say which kind it wants. Reading the
shell one when you meant the HTTP one finds no requests, which looks exactly
like a legitimately empty result.

## Never hand-write a cassette

Adding the missing interaction by hand makes the spex green while proving
nothing — and for these criteria, "nothing" is specifically *a message that
never arrived* or *a site that never served*. Record it or leave it red.

---

## Diagnosing a failure

ReqCassette's error names the request and lists every stored URI against the
attempted one. A provisioning step swallows it into `provider_error` and the
page truncates that, so to see the whole thing print `Exception.message(error)`
at the rescue in `Provisioning.run_and_record/4`.

Useful checks, in rough order of how often they are the answer:

    # what the cassette actually recorded, in order
    python3 -c "import json;d=json.load(open('test/cassettes/NAME.json'));\
    [print(i['request']['method'], i['request']['uri']) for i in d['interactions']]"

    # is the MX live
    dig +short MX <domain> @1.1.1.1

    # did anything leak
    mix cms.provisioning_leaks

    # does it pass alone but fail in the suite? then it is shared state,
    # not the cassette
    mix spex --pattern "test/spex/974_*/criterion_8030_*_spex.exs"

That last one is worth doing early. 8032 passed alone and failed whenever 8030
ran first, because 8030 exhausted a shared plug and the state carried.

## Known-red, and why

Some criteria assert things about the world that no cassette can stand in for —
a box in a provider console, a certificate a browser accepts, a post served on
a live site. Those need infrastructure standing, not a better test. When one is
red for that reason it should say so in its moduledoc rather than being tagged
out; a red spec with a reason is information, a skipped one is not.
