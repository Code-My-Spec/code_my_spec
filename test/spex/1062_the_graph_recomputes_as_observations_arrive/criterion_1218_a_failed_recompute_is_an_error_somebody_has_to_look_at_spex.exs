defmodule CodeMySpecSpex.Story1062.Criterion3248Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3248 — A failed recompute is an error somebody has to look at.

  Rule: a recompute that fails is raised loudly rather than retried quietly.

  ## The failure mode is silence, not the exception

  A recompute that raises leaves every reader served the last good answer. That
  answer looks correct and is frozen, and nothing about reading it says so — an
  agent asks what to work on, gets a plausible list, and works from a graph that
  stopped moving some time ago. Swallowing the exception and hoping the next
  unrelated observation recomputes is how that state lasts.

  So this asserts two things that are easy to have neither of: the failure is
  logged at error where a person greps, and it is on the graph's own answer
  where a reader looks.

  ## Driving a failure through a surface

  `POST /dev/faults` is the surface — the same one story 1064's criteria use —
  and `graph_recompute_fails` exists in `Faults` for this criterion by name.
  The route is compile-time absent from the release, so this drives a seam that
  only exists where it is safe to.

  The fault is keyed on the project, and cleared on exit. A leaked injection
  would make every later spex on this project fail in a way that looks nothing
  like its own subject.

  ## Why the work is wrapped in `capture_log`

  `SexySpex.ErrorCapture` fails a run on any logged error, which is right: a
  spex that logs an error and passes is hiding something. Here the logged error
  is the claim, so it is captured and asserted on rather than allowed to escape.
  `GraphWatcher`'s own comment warns about exactly this trap for anyone
  injecting this fault from a spex.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]
  import ExUnit.CaptureLog

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A recompute that fails says so where somebody will see it", criterion: 1218 do
    scenario "A failed recompute is an error somebody has to look at" do
      given_ :synced_context_component

      given_ "a graph that is computing normally", context do
        graph = read_settled_graph(context)

        assert graph["nodes"] != [],
               "nothing is computing yet, so a failure cannot be told from a cold start"

        refute get_in(graph, ["watcher", "last_error"]),
               "this project is already carrying a recompute error before one was injected"

        {:ok, Map.put(context, :before, graph)}
      end

      given_ "its next recompute is made to fail", context do
        project_id = context.project.id

        conn =
          Phoenix.ConnTest.build_conn()
          |> post("/dev/faults", %{"key" => project_id, "fault" => "graph_recompute_fails"})

        assert json_response(conn, 200)

        # A leaked injection makes every later spex on this project fail for a
        # reason that has nothing to do with its own subject.
        on_exit(fn -> CodeMySpec.Faults.clear(project_id, :graph_recompute_fails) end)

        {:ok, context}
      end

      when_ "an observation arrives that would have moved the graph", context do
        logged =
          capture_log(fn ->
            create_story(context.scope,
              title: "Arrives while the graph is broken",
              description: "and the recompute it triggers raises"
            )

            # Reading is what drives the pending observation through, so the
            # failure happens inside the captured block rather than after it.
            read_settled_graph(context)
          end)

        after_graph = read_graph(context)

        # The error this criterion is about is one this spex asked for, and
        # `SexySpex.ErrorCapture` is a `:logger` handler that records it
        # independently of `capture_log` — so the run fails on the very thing
        # being asserted unless the expectation is declared. `clear/0` is that
        # declaration, and it is called *after* both readings are taken so the
        # assertions below still run against what actually happened.
        #
        # Blunter than it should be: it drops every recorded error, not just
        # this one. The narrow assertion on `logged` below is what keeps that
        # honest — an unrelated failure in this block would not satisfy it.
        SexySpex.ErrorCapture.clear()

        {:ok,
         context
         |> Map.put(:logged, logged)
         |> Map.put(:after, after_graph)}
      end

      then_ "the failure was logged at error", context do
        assert context.logged =~ "recompute",
               """
               A recompute raised and nothing about it reached the log.

               The only remaining way to notice is to compare the graph's
               answer against a change you already knew about — which is to say,
               to already know.

               captured: #{inspect(String.slice(context.logged, 0, 400))}
               """

        {:ok, context}
      end

      then_ "and the graph says so when asked", context do
        assert get_in(context.after, ["watcher", "last_error"]),
               """
               The graph answered without mentioning that its last recompute
               failed.

               Every reader is now served the last good answer, which looks
               correct and is frozen. An agent asking what to work on gets a
               plausible list from a graph that stopped moving, and nothing in
               the response says so.
               """

        {:ok, context}
      end
    end
  end
end
