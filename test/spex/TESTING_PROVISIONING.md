# Testing provisioning: what each criterion is actually about

Written 2026-08-16, after a night in which the deploy was proven to work twice
and the suite still could not say so.

The question this answers: for a given criterion, is the claim about **our
logic** or about **reality**? The answer decides how it should be tested, and
getting it wrong is what has been costing weeks.

## Why record/replay fails here

A cassette assumes the response *is* the effect. That holds for a stateless
read — `GET /domains` returns JSON and nothing else happened. Provisioning
breaks all three of its assumptions at once:

* **Calls have effects outside the response.** `ssh-keygen` writes a key file;
  a create boots a box. On replay the stdout comes back and the file does not,
  so the next step diverges. This is exactly why 963/7965 records green and
  replays red: the recording's first run left a key on disk, so its second run
  never called `ssh-keygen` — and the replay's first run leaves nothing, so its
  second run asks for a recording that was never made.
* **State accumulates across calls.** Create-then-list means the second call's
  correct answer depends on the first having happened. A tape has one fixed
  answer per request.
* **The code changes what it calls.** Every provider call added invalidates
  every recording that predates it, silently, and the failure names a stub
  rather than the omission. Four modules have now been added to
  `provider_modules/0` after being bitten (`c635d90e`).

Live testing fails differently: 23 minutes per run, real money, an 8-primary-IP
ceiling, and a Resend token that expires at ~15 minutes — mid-sequence, which
is why 841/1961 has to record in two segments.

## The three layers

**1. Stateful fakes — the sequence.** A fake holding a map: create adds, list
reads, create-twice is idempotent, delete removes. It reproduces *effects*,
which is the thing cassettes cannot do. Fast, deterministic, and immune to the
rot: adding a provider call means teaching the fake, not re-recording nine
tapes.

**2. Contract tests per adapter — rarely.** Small and focused: "create returns
an id, and it appears in list". This is where record/replay genuinely fits,
because one request/response *is* the whole interaction. Run on adapter change
or nightly. They are what keep the fakes honest.

**3. The drill — live, unrecorded, scheduled.** One real end-to-end run. It
either works today or it does not. This already exists and is what proved the
deploy on 2026-08-16: both boxes, DNS, HTTPS at c1961.legwork.ca, twelve of
fourteen steps in 23 minutes.

## What happened: the whole epic converted

Written as a plan for converting the logic third "as they next break". All of
it converted instead, over 2026-08-16: 841, 963, 964, 965, 966, 967, 968, 969,
971, 972, 973, 974 and 985 run against fakes. The suite is 964 spex, green, in
under four minutes — 841's fourteen provisioning steps take 1.9 seconds where
they took fourteen minutes and a Resend token that expired partway.

Two things stayed recorded, and the reason is the same for both: their subject
is a real binary or a real filesystem, so a fake answering them would be
asserting its own implementation.

| Kept real | Why |
|---|---|
| 967's six encryption criteria | "The value in the repo is ciphertext", "a UAT key will not open production's secrets". The shell fake keeps plaintext dotenv on both sides of the door — round-tripping is what the *other* criteria need from it. |
| 964/7987, 971/8022 | Both scan the working tree for leaked credential values. A memory filesystem holding nothing finds no leaked credential for the same reason it finds no files. |

Reality claims did not disappear; they moved to where they can be answered. A
certificate a browser trusts, an image running on real hardware, mail actually
delivered — those belong to the drill, and 966 keeps them with an injected
probe so the criterion still asserts that setup *checked*.

## What the conversion actually taught

**A premise that was a fact about somebody's account.** Most conversions failed
first on this. "Sam owns his domain" was true because John's Cloudflare
manages `astralbi.com`. "A repository already exists" was true because an
earlier run left one — so those criteria passed on a dirty account and failed
on a clean one. "An under-scoped token" was a token narrowed by hand. Each is
now a line in the spex: `zone_exists/2`, `repository_exists/3`,
`grant_cannot_use_the_registrar/1`, `push_is_rejected/1`, `migration_fails/1`,
`dumps_stopped_landing/4`, `visitor_message_from/2`, `widget_backend_is_down/1`.

**Publishing and observing must be the same fact.** Three seams answered the
question "does this record resolve" from three different places — a DoH
request, a plain `:dns_resolver` function, and a table of names recorded on an
earlier day. They all read the zone now, so publishing a record is what makes
it resolve. Same for the site: it serves what publishing put in the bucket, and
answers 404 where nothing was published. An unconditional 200 passes a run that
provisioned one environment and forgot the other.

**`fake_providers` without `fake_working_directory` is half a spex.** Half of
setup is HTTP and half is a subprocess. Installing only the first leaves the
server step running a real `ssh` against the TEST-NET address the fake handed
back, which never returns — reported three minutes later as a LiveView
timeout, naming neither half. Cost most of a session.

**A fake that says no is worth more than one that says yes.** Unmodelled
commands exit 127 naming themselves; unmodelled routes answer 501. Every
fidelity gap in this conversion was found by a criterion failing loudly rather
than by reading the code: a dump that landed nowhere, a lifecycle rule the
create-bucket route swallowed, a constant `LastModified` that made every dump
the same age, `sops` that exited 0 while printing nothing.

**And one product bug**, which is the point of the exercise: a project set to
`devops: :uat` was getting a production server, DNS record and database built
anyway. It hid behind a green — the prod steps succeeded, so status reported
complete and the criterion whose whole subject is this passed on an assertion
that could only see the missing list.

## The structural change worth making regardless

Split the suites. A slow, network-dependent, real-world test currently blocks
the stop gate for every session, including ones that never touched it. Layer 1
belongs in the blocking gate. Layers 2 and 3 belong on a schedule, reporting
somewhere visible but not gating.

## What not to do

Do not fake a claim about reality. The test for whether a fake may answer a
criterion is whether the fake would be asserting its own implementation — that
is what rules out 967's encryption criteria and the working-tree scans, and it
is a sharper line than "logic vs reality" turned out to be in practice.

Do not keep the local fleet. It has the costs of reality — must be running, a
machine-local key that is gitignored, real SSH — without the fidelity: no
systemd, no sudo, unlike the Hetzner box it stands in for. That combination
produces failures that exist on one machine, which is the worst category to
own. Story 968 is parked on exactly this.
