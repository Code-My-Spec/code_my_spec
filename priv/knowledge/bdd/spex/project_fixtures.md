# Project Fixtures — building a real-ish project for a spec

A spec that claims something about a *project* needs a project to claim it
about. There are four ways to get one, and they cost between a millisecond
and half a second. Pick the shallowest layer that can actually be wrong if
the code is wrong.

## The two halves, and the seam between them

Two independent fixture systems exist, and they do not meet on their own:

| System | What it moves | What it does NOT do |
|---|---|---|
| `ProjectStateFixtures` | The **requirement graph** — DB rows advancing the project through its serial chain | Writes no files. A project can be `architecture_designed` with an empty filesystem |
| `InMemoryEnvironment` + `Fakes.Shell` | The **filesystem** — a memfs the real sync code reads | Moves no requirements by itself. Files can exist that nothing has noticed |

Most spec bugs at this layer come from assuming one implies the other. It
does not. If your claim is "the graph reacted to a file", you must write
the file **and** run the thing that notices it.

## The four layers

### 1. Graph only — `ProjectStateFixtures`

Composable steps that advance the project past requirements that would
otherwise dominate the actionable wave. Until the chain clears, project-level
work hides component-level work, so a spec about a component sees nothing.

```elixir
given_ "the project chain is fully kicked off", context do
  ProjectStateFixtures.apply_project_kickoff(context)
end
```

The steps are composable and each is applied independently, so a spec
advances to exactly the state it needs and no further: `apply_project_kickoff`,
`apply_persona`, `apply_technical_strategy`, `apply_architecture`,
`apply_three_amigos_for_story`, `apply_bdd_spec_for_story`,
`apply_qa_complete_for_story`, `apply_story_chain_complete`, and others.

**Use when** the subject is graph behaviour — what is actionable, what is
blocked, what a gate says. **Do not** use it to fake a state the code under
test is supposed to produce.

### 2. Filesystem only — the memfs

```elixir
env = Fixtures.memory_environment_fixture(working_dir: "/memfs/env-42")
:ok = Environments.write_file(env, "lib/foo.ex", "...")
```

`setup_active_project` wires the env onto the scope, so LiveViews that
rebuild scope via `Scope.for_local_project/1` get *this* env rather than a
default `:local` one. `mtime` advances on every write, which is what lets
`FileSync.sync_changed/2` detect an update inside one spec run.

**Use when** the subject reads files — classification, validation, sync.

### 3. Files *and* graph — write, then make something notice

This is the layer worth understanding, because it is the one people get
wrong. Writing a file changes nothing on its own. Something has to read it:

```elixir
:ok = Environments.write_file(env, @spec_path, spec_file_content())
:ok = Environments.write_file(env, @impl_path, impl_file_content())

{:ok, sync_live, _html} = live(context.conn, "/projects/#{project.name}/sync")
sync_live |> element("button[phx-click='sync']") |> render_click()

component = Fixtures.get_component_by_module_name(scope, @component_module_name)
```

Driving the sync through the **UI button** rather than calling the sync
function keeps the spec on the real path — which is the whole point of a
spex, and is enforced by the spex boundary anyway.

**Use when** the claim is "an agent wrote a file and the system reacted".

### 4. A real generated application — `drill_working_directory`

```elixir
setup :setup_active_project
setup :drill_working_directory
```

Generates a **real** application on real disk by running the real chain:
`cms.new`, then `mix deps.get`, then the `cms_gen.*` generators a real
project gets. Generation costs about 0.4s.

This exists because the alternative was worse. It used to point at one
checkout reused by every run, which deployed a months-old snapshot of the
generator's output rather than exercising the generator — so the claim that
the generator produces a deployable application was never actually run. A
persistent checkout also manufactured failures: the deploy step commits the
run's own `.sops.yaml` and `envs/*.enc.env`, and six such commits accumulated
until a later run met `no identity matched any of the recipients`.

**Use when** the subject is a real subprocess — `sops` and `age` are
binaries that read and write actual files, and the memfs is invisible to
them. An encrypt reports success and the file it was meant to write is
nowhere, which surfaces three assertions later as "the encrypted file does
not carry the key".

## Commands with effects, not output

`Fakes.Shell` is a shell whose commands *do things* — it writes into the
environment's own memfs, so the effect is there for the next command to find.

A cassette records what a command **printed**; provisioning depends on what
it **did**. `ssh-keygen -f path` writes a key, `sops encrypt --in-place f`
rewrites `f`. On replay the stdout comes back and none of that happens, so
the next step reads a world the recording never left behind.

Install it with `Application.put_env(:<app>, :memory_shell, Fakes.Shell)`;
the memfs `cmd/4` consults that and otherwise delegates to `Local`.

**An unmodelled command answers non-zero, naming itself.** A shell that
silently succeeds at everything makes every step pass and proves nothing,
which is worse than the cassettes. If your spec needs a command that is not
modelled, model its *effect* — do not make it return `{"", 0}`.

## Shared givens: the rule of three

Shared givens live in `<App>Spex.SharedGivens`. Add one only after a **third**
spec duplicates the same setup. Two duplicates is still cheap to read inline;
three is where the pattern is worth naming.

A shared given **establishes state and does not assert**. If setup breaks,
let it break at the point of failure — a pattern-match or an `{:ok, _}`
mismatch. Assertions belong in `then_`.

Return `{:ok, Map.put(context, :key, value)}` — add to the context, never
replace it.

## Composing a project — `ProjectBuilder`

Builds a plausible project in the memfs, one piece at a time:

```elixir
project =
  ProjectBuilder.new(context.environment, app: "my_app")
  |> ProjectBuilder.context("Accounts")
  |> ProjectBuilder.component("Accounts", "User")
  |> ProjectBuilder.unit_test("Accounts")
  |> ProjectBuilder.write!()

project.paths     # every path written, in order
project.modules   # every module defined
```

**It does not reproduce what `cms.new` generates and must not pretend to.** A
fixture claiming to be the generator's output is wrong the first time the
generator changes, and wrong *silently* — every spec keeps passing against a
shape no customer has. For a claim about the generator, use layer 4.

What it does guarantee is that every path it writes is one
`Scanner.classify/1` recognises. That is the only interesting property, and it
is tested directly: an unclassified file never syncs, so a builder writing
where nobody reads would produce a project that looks full and behaves empty.

Nothing is written until `write!/1`, so a spec lands a project as one event
rather than a trickle the debounce coalesces unpredictably.

`spec_only/2` and `impl_only/3` exist because a spec without an implementation
and an implementation without a spec are *different* graph states — both
meaningful, neither the same as a complete context.

## Watching the graph move, and who got woken

`CodeMySpecTest.GraphHelpers` packages the observation most agent-behaviour
specs need:

```elixir
context
|> install_recording_transport()   # route wakes to this process
|> watch_graph()                   # ensure a watcher, subscribe to the topic

{:ok, _issue} = ...                # something happens

context
|> settle_graph()                  # do the pending pass NOW, never sleep

assert_woken(coding_agent.id, saying: "Work of your kind is available")
refute_woken(qa_agent.id)
```

Three things to know before using it:

**`settle_graph/1` instead of sleeping.** The watcher debounces, so a write
does not recompute immediately. `settle/1` performs the pending pass
synchronously. A spec that slept would assert the timer rather than the
mechanism, and would be flaky on a loaded box — which is where the analyzer
runs.

**`settle/1` answers `:ok` when nothing is watching.** So forgetting
`watch_graph/1` is not an error: nothing recomputes, no wake arrives, and the
absence looks exactly like correct role-scoping. `assert_woken/2` names this
possibility in its failure message because it is the easy mistake.

**A negative wake assertion costs real time.** `refute_woken/2` drains for a
window before concluding, because absence is only knowable by waiting. Always
pair it with an `assert_woken/2` on the agent that *should* have been told —
a scenario where nobody was woken passes the negative assertion for entirely
the wrong reason.

Wakes are observed through `RecordingAgentTransport`, whose config key is
global, so a spex using these helpers must be `async: false`.

## Known gaps

Honest about what this does not do yet, so nobody builds on a false floor:

- **`ProjectBuilder` is a fixture, not the generator.** It writes a tree the
  scanner recognises; it does not claim to be `cms.new`'s output, and a spec
  asserting anything about what a *generated* project contains must use layer 4.
- **Nothing in the application subscribes to `{:graph_updated, project_id}`.**
  Specs can (that is what `watch_graph/1` does), but the wake reaching an
  agent happens through a direct call to `Agents.wake_project_roles/1` inside
  the watcher's recompute, not through the broadcast. Two mechanisms, one of
  which currently has no production listener.
- **A failed recompute is swallowed.** `GraphWatcher.recompute` rescues,
  logs at `warning`, and carries on, on the reasoning that a watcher is a
  background convenience. That is at odds with how this system is supposed to
  fail — loudly, so the failure becomes an issue somebody fixes.
