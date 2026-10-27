# Handoff: test throughput — baseline-relative test selection ("stale v2")

Branch `claude/peaceful-knuth-ugokk3`, based on `c09d589` (main when written, 2026-10-27).
No PR is open. Nothing is wired into the promotion gate yet.

`.code_my_spec/` is a **git submodule** (pinned at `1397524d491d` when this was
written). References below into `.code_my_spec/` are to that checkout; it is a
separate repo, so nothing here was committed to it.

## Where to find it

| | |
|---|---|
| Repo | https://github.com/Code-My-Spec/code_my_spec |
| Branch | `claude/peaceful-knuth-ugokk3` (tip may be ahead of the commits below if this doc was amended later: `git log -3`) |
| Base | `c09d5890922c9ecbc36f704fb1b529256ab6c021` — "Promotion batch: merge 4271667e786e" |
| Spike | `ed0c5a6111f07443d07597d216a3b7d08cf79b7f` — adds `lib/code_my_spec/test_impact.ex`, `lib/mix/tasks/cms.test_affected.ex`, `test/code_my_spec/test_impact_test.exs` |
| Handoff + harness | `f2a187970e8d70270c3a6b293d203c418d51693c` — adds this file and `scripts/test_impact_toy_check.sh` |
| Whole change | `git diff c09d589..f2a1879` (5 files, +990 lines, no deletions, nothing outside these five touched) |
| Submodule | `.code_my_spec` pinned at `1397524d491dba245ae81f76aa9e80be5dd3edb9`; not modified |
| Session | https://claude.ai/code/session_01Wc1L6mFQx95mdVzv6tyiDV (the conversation these findings came from) |

```
git fetch origin claude/peaceful-knuth-ugokk3
git checkout claude/peaceful-knuth-ugokk3
scripts/test_impact_toy_check.sh        # expect 11 x SAME, exit 0
```

Citations are `[R#]`; the table in **References** says where each lives, what it
establishes, and **how much of it I actually read**. Treat anything marked
*excerpt*, *snippet* or *not read* as unverified.

---

## 1. The problem, in one paragraph

Promotion is serial and every candidate pays a full analyzer sweep. The gate
requires a run of *every* source at the exact commit [R6], exunit and spex are
requested with empty args so they sweep everything [R7], and the queue batches
one candidate at a time [R5]. Sweeps measured at 200–590 s [R8]. As agents
produce more, smaller candidates [R1], queue wait grows linearly with candidates
because the fixed per-candidate cost (gate build, test-database reset, format,
full sweep, asset build, landing [R5]) is paid for each.

Two things attack that: **run fewer tests per candidate** (this branch) and
**gate more than one candidate at a time** (not started; §7).

## 2. What Anthropic's article actually says (and does not)

[R1] is about the infrastructure *around* test selection, not the selection
algorithm. Read in full (the text was pasted into the session; the host is not
reachable from the sandbox).

- Test impact analysis = a **listener** (records every CI result) and a
  **selector** (reads that history to choose tests per PR). Selection is by
  past performance and package relevance — not a dependency graph.
- The listener was a single process because per-test history needed one writer.
  CI jobs grew 25x in six months (tests 10x, headcount ~flat); the listener fell
  behind the PR queue.
- Patches that bought less each time: bigger machine (70 days) → shard by
  package (29 days) → daily restarts (<1 day).
- **The real cost of lag was a stale selector**: flaky tests kept running, new
  or fixed tests did not run until the listener caught up, bad merges went
  unnoticed. Not "untested code shipped".
- Fix: give it a store. Stateless listener workers append to a journal; a small
  consumer rolls the journal into per-test history every few seconds; the
  selector reads the rollup. Three weeks, one engineer.
- Lessons stated: design the v0 for 10–20x; keep state out of the process; no
  critical singleton; instrument so **jobs in = jobs out**; agents prefer smaller
  PRs so job counts outgrow code volume.

Secondary write-ups [R2] exist; I only saw search snippets, so I did not rely on
them beyond the three patches and the journal design, which [R1] confirms.

**Mapping to this repo** (my reading, not the article's):

| Article | Here |
|---|---|
| Single-writer singleton, state in memory | `PromotionQueue.Worker` is one GenServer per project with `phase`/`batch` in memory [R5]; `Analysis.ProjectServer` holds `queue` and `waiters` in memory per working copy [R8] |
| Shard by key | Analysis already shards by working copy [R8]; the queue is per project with `@batch_cap 1` [R5] |
| Survive restart | Mostly done for the queue (`requeue_gating`, `persist_publication`, `recover_publication` [R5]); `ProjectServer`'s queue is not durable |
| Stale selector input | `fresh: true` / "certified on runs recorded before you promoted" [R5 `note_reused`]; `--stale` manifest drift |
| jobs in = jobs out | No counter I could find for runs started vs terminal or entries enqueued vs terminal. The `@gate_wait_limit_ms` comment ("a run row nothing will ever close") shows leaks have happened [R5] |

## 3. How `mix test --stale` really works (read in the installed source)

Source: Elixir 1.19.4 at `/opt/elixir/lib/mix/lib/mix/compilers/test.ex` [R3].
Upstream GitHub was not reachable; the upstream path is the same file on `main`,
which may differ from 1.19.4.

- Two inputs: the **test manifest** `compile.test_stale` (per test file: modules
  it references at compile and runtime, plus `external` files) and the **Elixir
  compile manifest** `compile.elixir` (who references whom) [R3 `:119-176`,
  `:237-289`].
- Staleness is **mtime-based**: beams newer than the test manifest seed the stale
  module set; `config`, `mix.exs`, `test_helper.exs` newer than it force a full
  run [R3 `:129`, `:245-250`].
- The closure follows **runtime, compile and export** references transitively
  [R3 `:263-289`]. (I previously guessed it might be compile-only; it is not.)
- The manifest is only rewritten when `failures == 0` [R3 `:102`], so a red run
  does not advance it. The *compile* manifest advances regardless.
- First `--stale` run in a `_build` runs everything and writes the manifest [R4].

Consequence: `--stale` answers "what changed since the last `--stale` run in this
`_build`", a fact about one directory's history. The stop hook already relies on
it and says so: "We pass --stale and trust it" [R12]. The gate does not use it
[R7, R9].

## 4. What is built on this branch

Commit `ed0c5a6` plus the handoff commit. Files [R14]:

- `lib/code_my_spec/test_impact.ex` — `CodeMySpec.TestImpact.select/2`, pure.
  Same closure as stock, but the seeds are modules defined in files named by
  `git diff`, not beams newer than a manifest. Also `read_baseline/1`.
- `lib/mix/tasks/cms.test_affected.ex` — `MIX_ENV=test mix cms.test_affected
  --base REF [--head REF] [--manifest-dir DIR] [--json] [--explain] [--strict]
  [--force-full GLOB]`. Plain output: one test file per line.
- `test/code_my_spec/test_impact_test.exs` — 13 unit tests.
- `scripts/test_impact_toy_check.sh` — reproducible comparison against stock
  `--stale` on a toy project [R15].

**Why the baseline's graph is enough for the forward direction**: any new
reference in the changed tree starts in a changed file, so the module that gained
the edge is already a seed. A deleted module is in the baseline manifest, so it
seeds too. A new test file is absent from the test manifest, so it is selected.

**Fail-closed behaviour**: whole suite when the diff touches `config/**`,
`mix.exs`, `mix.lock`, `**/test_helper.exs` or `priv/repo/**`, when the baseline
manifests are missing, or when they are not the layouts this Mix release writes
(test manifest vsn 2 [R3 `:20`], compile manifest vsn 29 [R3b `elixir.ex:8`]).
Changed non-Elixir files that no manifest knows are reported as `unclassified`
(and force a full run with `--strict`).

## 5. Evidence and its limits

Run `scripts/test_impact_toy_check.sh` [R15]. 11 scenarios, **11/11 match stock
`--stale`**: edit at the root, middle and leaf of a chain; independent module;
comment-only edit; `@external_resource` change; new test; edited test; macro
(compile-time) edit; config change (whole suite); unrelated file; deleted module
plus its test. Unit tests: 13/13, run inside the toy project.

What this does **not** show:

- **Not run in this repo.** The sandbox could not fetch Hex deps, so
  `mix compile`, Boundary checks and the repo suite have not been run on the new
  files. Formatting was checked with the repo's settings only. **First task:
  compile and run the unit tests in-repo.**
- **Equivalence with stock `--stale`, not soundness against a full run.** The
  toy proves the reimplementation is faithful. It says nothing about whether
  stale-style selection misses real failures in this codebase.
- No replay on real landed candidates. No selection-ratio number exists.

Known blind spots, shared with stock: dynamic dispatch through computed atoms;
files read at runtime but not declared `@external_resource`; cassette-driven
spex, whose dependency on code is not compile-time [R13 *excerpt*].

## 6. Open questions the next agent must answer before wiring in

1. **What does the gate accept as an exunit "answer"?** `Promotion.gate`
   requires every source to have a run at `head` [R6 `:932-947`] and a run counts
   only if the harness saw it start on a clean tree at that commit and finish
   there (`Analysis.answer_at_commit/3`) [R10]. I did **not** trace
   `answer_at_commit` or `Analysis.Run` kinds. Runs with path args are `:partial`
   and "refresh only those files' problems" [R7 `:80-110`]. A selective run that
   is not a full sweep needs a new answer kind that records its selection.
2. **Problems are kept per copy, not per commit** [R6 `:1030-1037`]. A selective
   run leaves the non-run tests' problems from an earlier commit in place. Decide
   how a partial answer composes with them without false blocks or false clears.
3. **Baseline lifecycle.** The task needs manifests from a green main run. Who
   owns that build, per device? The gate copy is per device (`promotion-gate:
   device:<id>`) and has its own `MIX_BUILD_PATH` per working copy [R5, R8]. After
   a landing the gate's green run at the published commit *is* main's new state,
   because the published commit is the certified commit [R5 `land`]. A red or
   ejected run must not advance it (stock already refuses to for the test
   manifest [R3 `:102`]; the compile manifest still advances, so use a clone).
4. **Spex.** `mix spex --stale` is also in use [R12], but `Spex.execute` is a
   separate path [R7-adjacent `runners.ex:170`] and cassette-driven. Not assessed.
5. **Where the task lives.** I put it in this repo to follow the `cms.*`
   pattern. Target projects already load `ClientUtils.TestFormatter` from the
   `client_utils` dep (`mix.exs:215`, `== 0.3.0`), so shipping it there would
   reach them without touching target repos. Not decided.
6. **Elixir version coupling.** Manifest layouts are Mix-private. CI's Elixir
   should match the harness's; mismatch only costs a full run by design.
7. **Tree-hash certification: lower value than I first said.** Keying a run on
   `git rev-parse <commit>^{tree}` would let identical trees share an answer, but
   only for amends, same-tree rebases and re-promotions, not the common path. The
   gate note records that fingerprint-based freshness "had several definitions and
   stalled the fleet" [R10]; that was about work-tree fingerprints, not content
   hashes, but read it before proposing anything keyed other than on the commit.
   Any key must also cover path dependencies (`client_utils`, the reason
   `fresh: true` exists [R5]) and the toolchain.

## 7. Suggested order of work

1. **Compile and test in-repo.** `mix compile`, `mix format --check-formatted`,
   `mix test test/code_my_spec/test_impact_test.exs`. Fix anything Boundary or
   the repo's compiler flags find.
2. **Measure before building more.** Pull per-source run duration and queue wait
   (from the `Run` and `Entry` records [R5, R7]; I did not write the queries) to
   see whether time goes to exunit/spex sweeps (selection helps) or to gate
   rebuilds and waits (parallel gates help).
3. **Replay.** For the last ~30 landed candidates: build the base, run
   `cms.test_affected --base <base> --head <head>`, compare against what a full
   run at head found failing. Record selection ratio and any miss. A miss is the
   finding; widen the force-full list or fix the graph, don't dismiss it.
4. **Define the gate answer** (§6.1–6.2) and wire selection into
   `Promotion.gate` / `Analysis` behind a flag, keeping the periodic full sweep
   on main as the safety net.
5. **Candidate-side proof, queue-side verification.** Candidate submits
   `{base, head, selected tests, results}`; the queue recomputes the selection
   from the same pure function and checks the submitted list is a superset. That
   is what makes it a proof, not an honour system.
6. **Speculative merge in the queue.** Merge, compile the whole tree (never
   selective, never relaxed), then run the affected set of the *merged* diff
   `main..batch`. This catches semantic conflicts between candidates that each
   passed alone (changed contract + new caller, etc.). Then consider raising
   `@batch_cap` [R5 `:40`] or running parallel gate lanes, with a single
   serialised lander that re-checks `base == main` (`on_current_main`, `:base_moved`
   already do this).
7. **Instrument "in = out".** Counters and an age alert for runs started vs
   terminal, entries enqueued vs terminal, queue depth and oldest-entry age [R1].
8. **Later, if measurement says so:** move `ProjectServer`'s in-memory queue and
   waiters into the DB so dedup is a constraint, not process memory [R8]; try
   seeding on changed beam MD5 so comment/format-only edits select nothing
   (unverified whether line-number shifts change the MD5; stock and this branch
   both reselect dependents on a comment-only edit, scenario 4 in [R15]).

## 8. Traps already hit

- **Never restore a test fixture with `git checkout`.** It gives restored files
  fresh mtimes and stock `--stale` reads them as changes. This produced three
  false DIFFs. Use `cp -a`.
- **Build the baseline in the directory the scenarios run in.** `_build` holds
  absolute paths (e.g. the `priv` symlink); a moved project recompiles
  everything and stock then runs every test.
- **The compile manifest and test manifest store externals differently**:
  `{path, mtime_and_size, digest}` vs bare path. The first version missed this and
  an external-resource change selected nothing. Covered by tests now.
- **Do not weaken the compiler run.** Cross-candidate semantic conflicts are
  mostly caught by a full compile; the gate note says the compiler run is
  `--force`d for a reason [R10].
- The toy shows equivalence with stock `--stale`. Do not quote it as evidence that
  selection is safe.

## 9. Not done / not verified (stated plainly)

Not compiled or tested inside this repo; not wired to the gate; no replay; no
timing data; `answer_at_commit` and the `Run` kinds not read; spex not assessed;
upstream Elixir `main` not compared with 1.19.4; secondary article coverage not
read beyond snippets.

---

## References

Status: **full** = read end to end; **excerpt** = read the cited range only;
**snippet** = saw a search-result summary only; **unreachable** = tried, blocked.

| ID | What | Where | Establishes | Status |
|---|---|---|---|---|
| R1 | Anthropic, *Agentic coding is straining CI. Here's how we scaled test impact analysis at Anthropic*, S. Malhotra, 2026-09-14 | https://claude.com/blog/agentic-coding-is-straining-ci-heres-how-we-scaled-test-impact-analysis-at-anthropic (the `/resources/articles/...` form the user gave is the same piece) | Listener/selector design, the three patches, stale-selector consequences, journal redesign, lessons | **full** (pasted text); URL **unreachable** from sandbox (DNS/proxy 403) |
| R2 | Secondary write-ups: explainx.ai, highcircl.com, digitalapplied.com, getreadyforagents.com | https://explainx.ai/blog/anthropic-test-impact-analysis-ci-scaling-2026 · https://www.highcircl.com/en/blog/anthropic-ci-test-impact-analysis-scaling | Corroboration only | **snippet** |
| R3 | Elixir 1.19.4 `Mix.Compilers.Test` | `/opt/elixir/lib/mix/lib/mix/compilers/test.ex` `:12-20` (record, vsn 2), `:102` (manifest written only on 0 failures), `:119-176` (`set_up_stale`), `:129` (force on config/mix.exs/test_helper mtime), `:237-261` (`tests_with_changed_references`), `:263-289` (`find_all_dependent_on`, runtime+compile+export). Upstream: https://github.com/elixir-lang/elixir/blob/main/lib/mix/lib/mix/compilers/test.ex | Exactly what `--stale` computes | **excerpt** of the stale path (`:36-295`); upstream **unreachable** |
| R3b | Elixir 1.19.4 `Mix.Compilers.Elixir` | `/opt/elixir/lib/mix/lib/mix/compilers/elixir.ex` `:8` (manifest vsn 29), `:13-26` (`module`/`source` records), `:311` (`read_manifest/1`) | Compile-manifest layout this branch reads | **excerpt** |
| R4 | `mix test` task docs, "The --stale option" | `/opt/elixir/lib/mix/lib/mix/tasks/test.ex:430-455`; flag at `:205`; `--failed`+`--stale` rejected at `:976` | First run runs all and writes manifest | **excerpt** |
| R5 | `CodeMySpec.PromotionQueue.Worker` | `lib/code_my_spec/promotion_queue/worker.ex`: `@batch_cap 1` `:40`; `reserve_next` `:159`; `level_with_main` `:253-271`; `build_in_gate_copy` `:275`; `reset_test_databases` `:290`; `format_then_gate` `:316`; `gate` `:483`; `gate_runs` `:492`; `assets_build` `:512`; `failed_runs` `:525`; `stories_green` `:554`; `land` `:659`; `note_reused` `:833`; gate-wait limits `:42-44`, `:356-373` | The serial per-candidate pipeline and its fixed costs | **full** (whole file) |
| R5b | `CodeMySpec.PromotionQueue` | `lib/code_my_spec/promotion_queue.ex` (`enqueue`, `promote`, `ensure_worker`, `resume_all`) | Admission checks, durability on boot | **full** |
| R6 | `CodeMySpec.Promotion` gate | `lib/code_my_spec/promotion.ex`: doc `:932-947`, `gate/3` `:950`, `certified_at?` `:1010`, `blocking_problems_at` doc `:1030-1037`, `answers_at` `:1060`; comment "Keyed on the commit, never on fingerprints" `:929` | Every source needs a run at `head`; problems kept per copy | **excerpt** (`:920-1070`) |
| R7 | `CodeMySpec.Analysis` | `lib/code_my_spec/analysis.ex`: `@full_args` `:73-78` (exunit/spex `[]`); `ensure_stale_runs/3` `:102`, partial-run doc `:80-110`; mode `:66-69` | Gate runs sweep everything; partial runs only refresh some problems | **excerpt** (`:60-90`) |
| R8 | `CodeMySpec.Analysis.ProjectServer` | `lib/code_my_spec/analysis/project_server.ex`: moduledoc `:2-43`; `@job_timeout` `:54`; `@source_cost`/`order` `:238-245`; `maybe_start_next` `:247` | Per-copy serialised analysis, in-memory queue, sweeps 200–590 s, per-copy build/test DB | **full** (whole file) |
| R9 | `CodeMySpec.Tests.execute/2` | `lib/code_my_spec/tests.ex:48` (`mix test --formatter ClientUtils.TestFormatter | args`), `partition_env` `:92-111` | Gate invokes bare `mix test`; per-copy test partition | **excerpt** (`:1-130`) |
| R10 | Promotion knowledge note | `.code_my_spec/knowledge/promotion/index.md:148-169` ("The gate") | Commit-keyed answers; fingerprint freshness "stalled the fleet"; compiler run is `--force`d | **excerpt** |
| R11 | Analysis knowledge note | `.code_my_spec/knowledge/analysis/index.md`: `:125` "A run that saw nothing is not clean", `:144` "Never drop diagnostics", `:214` "Test databases" | Why empty/zero-test runs fail rather than pass | **not read** (headings located by grep only) |
| R12 | Validation pipeline rules | `.code_my_spec/issues/validation-pipeline-redesign/rules.md:13-15`, `:41-44` ("We pass --stale and trust it") | The stop hook already uses `--stale` and `spex --stale` | **full** |
| R13 | Spex recording cassettes | `priv/knowledge/bdd/spex/recording_cassettes.md:5` and following | Spex can replay recorded tool output, so code dependency is not compile-time | **excerpt** (grep context only) |
| R14 | This branch's code | `lib/code_my_spec/test_impact.ex`, `lib/mix/tasks/cms.test_affected.ex`, `test/code_my_spec/test_impact_test.exs`; commit `ed0c5a6` on `claude/peaceful-knuth-ugokk3` | The spike | **full** (written here) |
| R15 | Toy comparison harness | `scripts/test_impact_toy_check.sh` (exit 0 = all scenarios match stock) | Reproduces §5 | **full**; last run 11/11 SAME |
| R16 | Client dep that already ships into target projects | `mix.exs:215` `{:client_utils, "== 0.3.0"}`; formatter `ClientUtils.TestFormatter` in R9 | Candidate home for the task | **excerpt** |
