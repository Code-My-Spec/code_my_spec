defmodule CodeMySpecSpex.Story1062.Criterion3248Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3248 — A failed recompute is an error somebody has to look at.

  Rule: a recompute that fails is raised loudly rather than retried quietly.

  The failure this story can produce that nothing else can. Every other way the
  graph goes wrong shows up as a wrong answer; this one shows up as the *right*
  answer, held still. Readers go on being served the last good computation,
  which looks correct and is frozen, and the only symptom is agents working
  from a graph that quietly stopped moving — the 1063 failure with no cache bug
  behind it.

  So the failure has to announce itself, at the level somebody actually looks
  at, and it has to stay visible after the moment it happened.

  ## The fault is a real one

  Deleting a project while a watcher is still running for it. The watcher's
  next pass asks `Configurations.get_or_create/1`, whose insert is refused by
  `project_configurations_project_id_fkey`, and the recompute raises. Nothing
  here is injected: the project is deleted through the projects page, by the
  button a person clicks.

  The window is held open so the deletion lands while a pass is still owed —
  which is the whole situation, a watcher carrying work for a project that is
  no longer there.

  ## Observed as a log, deliberately

  Every other criterion on these two stories reads a page or an API. This one
  cannot: the surface that would show a project's watcher is the project's own,
  and the fault is the project being gone. Anything that could report it has
  been deleted along with it.

  An `:error` log is the surface that survives that, and it is the one this
  project is operated from — `CLAUDE.md` is largely a guide to reading these
  logs. The assertion is specifically that it is `:error` and not `:warning`:
  the level *is* the criterion. It was `:warning` until this was written, which
  put a frozen graph in the same bucket as a retry.

  `fail_on_error_logs: false` because the scenario drives an error path on
  purpose; that is SexySpex's documented escape rather than a way around a
  failure.
  """

  use CodeMySpecSpex.Case

  # The projects page is a cloud-app surface. The case defaults to the local
  # app, whose own projects page runs on a scope with a different account and
  # refuses the delete on `project.account_id == scope.active_account_id`.
  @endpoint CodeMySpecWeb.Endpoint

  import ExUnit.CaptureLog

  alias CodeMySpec.Issues
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :hold_graph_window

  # The watcher recomputes in its own process.
  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A recompute that fails says so", fail_on_error_logs: false do
    scenario "the project is deleted while a pass is still owed" do
      given_ "a watched project with a pass owed to an observation", context do
        :ok = CodeMySpecSpex.Fixtures.watch_graph(context.scope)

        {:ok, _issue} =
          Issues.create_issue(context.scope, %{
            title: "the observation that owes the pass",
            description: "filed so the watcher has work in hand when the project goes",
            severity: :medium
          })

        {:ok, context}
      end

      when_ "the project is deleted from the projects page, and the pass comes due",
            context do
        {:ok, live, _html} = live(context.conn, "/app/projects")

        # What the page's confirm dialog pushes: its `on_confirm` is
        # `JS.push("delete", value: %{id: project.id})`. Clicking the button
        # only opens the dialog, so driving the button would delete nothing.
        render_click(live, "delete", %{"id" => context.scope.active_project_id})

        logged =
          capture_log([level: :error], fn ->
            :ok = CodeMySpecSpex.Fixtures.settle_graph(context.scope)
          end)

        {:ok, Map.put(context, :logged, logged)}
      end

      then_ "the failure was reported at a level somebody looks at", context do
        assert context.logged =~ "[GraphWatcher] recompute failed",
               """
               A recompute failed and nothing was logged at :error.

               This is the one failure on this story that does not produce a
               wrong answer. Every reader keeps getting the last good graph,
               which looks right and never moves again, and agents go on
               deciding from it. Reported below :error it sits in the same
               bucket as a retry — something that resolved itself — and the
               frozen graph is found days later by someone wondering why an
               agent stopped making progress.

               captured at :error:
               #{inspect(context.logged)}
               """

        {:ok, context}
      end
    end
  end
end
