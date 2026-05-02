# Spex — BDD Acceptance Tests

Spex are the BDD acceptance-testing framework shipped with the harness. They are executable
specifications that exercise the system **only through its real interaction
surfaces** — the same surfaces a human user or a coding agent would use in
production.

A spec is a contract, not just a test. Its job is to make it structurally
impossible to "cheat" by calling internal APIs: if a spec needs something
the public surface doesn't expose, either the surface is wrong or the
scenario is wrong.

## Where to look

| Topic | File |
|---|---|
| Why specs are shaped this way | [philosophy.md](philosophy.md) |
| File layout, DSL, setup template | [writing_a_spex.md](writing_a_spex.md) |
| What you can and can't call from a spec | [boundaries.md](boundaries.md) |
| In-memory filesystem, cassettes, hooks | [environment.md](environment.md) |
| Recording cassettes + JSON output fixtures | [recording_cassettes.md](recording_cassettes.md) |
| When to extract a shared given | [shared_givens.md](shared_givens.md) |

## Quick orientation

- Specs live at `test/spex/<story_id>/<criterion_id>_spex.exs`.
- One criterion = one `spex` block. One `spex` may contain one or more
  `scenario` blocks.
- The only module a spec is allowed to reach into the app through is
  `<App>Spex.Fixtures`. This is enforced by the `Boundary` deps
  declared on `<App>Spex` — specs can't even import the core app.
- Run the whole suite with `mix spex`.

## The two users

The product has two users, and every spec should frame its `when_` step
as one of them taking an action:

- **Engineer** — interacts through the local Phoenix LiveView
  (`<App>LocalWeb`). Drive them with
  `Phoenix.LiveViewTest.{live, form, render_submit, render_click}`.
- **Coding agent** — interacts by writing files into the working
  directory and by firing harness hooks (stop hook, etc.). Drive this
  with `Environments.write_file/3` and `Phoenix.ConnTest.post/3` to
  `/api/hooks/*`.

If a step needs to reach past those two surfaces to make the scenario
work, stop and re-read [boundaries.md](boundaries.md) before proceeding.
