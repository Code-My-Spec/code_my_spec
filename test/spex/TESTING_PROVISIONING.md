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

## Classification of what is currently failing

**Logic — belongs against a fake, should be milliseconds**

| Criterion | Claim | Why it is logic |
|---|---|---|
| 963/7965 | Running a step twice leaves one of everything | Idempotency of our step, not of Hetzner. Cost ~100s and a real server tonight and still does not replay. |
| 969/8029 | Existing inbound mail survives the sending setup | That we do not touch the apex MX. A fake zone answers this. |
| 972/8058 | A lost trigger is reported, not swallowed | Our error handling on a failed trigger. |
| 992/8233 | Deploying builds the image on demand | That the deploy step *asks* for a build and records what it got. |

**Reality — belongs in the drill or a live scheduled run**

| Criterion | Claim | Why no fake can answer |
|---|---|---|
| 965/7996 | The records let the proxy get its certificate | A real ACME challenge against a real resolver. |
| 966/8006 | Answers on his domain over a valid certificate | A real TLS handshake. |
| 966/8010 | Every public hostname answers before done | Real DNS, real HTTP. |
| 974/8030, 8032, 8048 | Inbound mail arrives, survives, is acted on | Real mail delivery through Resend. |
| 992/8234 | The image runs on the architecture the box runs | A real box, a real image. |

Split of the current 14: roughly a third logic, two thirds reality. The logic
third is where the recurring maintenance has been going, and it is the third
that never needed a recording.

## The structural change worth making regardless

Split the suites. A slow, network-dependent, real-world test currently blocks
the stop gate for every session, including ones that never touched it. Layer 1
belongs in the blocking gate. Layers 2 and 3 belong on a schedule, reporting
somewhere visible but not gating.

## What not to do

Do not rewrite eighty spex. Classify, and convert the logic ones as they next
break. The table above is a starting set.

Do not keep the local fleet. It has the costs of reality — must be running, a
machine-local key that is gitignored, real SSH — without the fidelity: no
systemd, no sudo, unlike the Hetzner box it stands in for. That combination
produces failures that exist on one machine, which is the worst category to
own. Story 968 is parked on exactly this.
