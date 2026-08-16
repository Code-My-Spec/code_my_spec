defmodule CodeMySpecSpex.Story1014.Criterion2376Spex do
  @moduledoc """
  Story 1014 — An agent that has gone quiet stops holding state for everyone else.
  Criterion 2376 — A quiet agent's files and problems are reclaimed.

  Rule: An agent quiet longer than the configured window has its derived state
  reclaimed.

  Files and problems are projections. The working copy is the truth for files, and
  problems are properties of the codebase — an agent that comes back runs analysis
  and produces them again. Keeping either across an absence preserves nothing and
  blocks other people's gates meanwhile.

  ## Driven and read through surfaces, not the database

  The `when_` is the stop hook, because that is what a live agent actually does
  and because the reclaim rides on the component sync the hook triggers rather
  than on a schedule. Nothing here calls the sweep directly; if the wiring is
  wrong this fails, which is the point.

  The `then_` reads the files view, for the same reason: a query would pass
  against a reclaim that emptied a table nobody renders, and would keep passing if
  the view later read from somewhere else. What an engineer sees is the claim.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecLocalWeb.Endpoint

  @gone "lib/gone_context.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A quiet agent stops holding derived state" do
    scenario "A quiet agent's files and problems are reclaimed" do
      given_ :synced_context_component

      given_ "a second checkout, quiet for days, whose files the project still lists",
             context do
        quiet = Fixtures.quiet_harness_fixture(context.scope, 96)
        Fixtures.observe_files_as(context.scope, quiet, [@gone])

        # Aged again, after the manifest rather than before it. Pushing a
        # manifest is proof of life and renews `last_seen_at`, so a checkout
        # that reports its files and *then* goes quiet is the real sequence —
        # aging it first and observing second describes an agent that left and
        # kept working, which is not a thing.
        quiet = Fixtures.go_quiet(quiet, 96)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files?harness=#{quiet.id}")

        assert render(view) =~ @gone,
               "the premise failed: the quiet checkout's file is not listed, so there " <>
                 "is nothing for the reclaim to remove"

        {:ok, Map.put(context, :quiet, quiet)}
      end

      when_ "a live agent stops, which syncs components", context do
        report =
          hook(context, "/api/hooks/stop", %{
            "session_id" => "spex-live-#{System.unique_integer([:positive])}"
          })

        {:ok, Map.put(context, :report, report)}
      end

      then_ "the project no longer lists the quiet checkout's files", context do
        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/files?harness=#{context.quiet.id}"
          )

        refute render(view) =~ @gone,
               "a checkout nobody is running is still holding file rows. The working " <>
                 "copy is the truth and the rows are a projection, so keeping them " <>
                 "across an absence preserves nothing — and they hold components alive " <>
                 "for everyone else on the project."

        {:ok, context}
      end

      then_ "the live agent is not told about the quiet one's problems", context do
        refute inspect(context.report) =~ @gone,
               "the stop response still carries problems belonging to a checkout " <>
                 "nobody is running. Problems are properties of the codebase, not of " <>
                 "the database: an agent that comes back runs analysis and produces " <>
                 "them again. Holding them meanwhile only blocks the agents still " <>
                 "working. Got: #{inspect(context.report)}"

        {:ok, context}
      end
    end
  end

  defp hook(context, path, params) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Phoenix.ConnTest.dispatch(@endpoint, :post, path, params)
    |> Phoenix.ConnTest.json_response(200)
  end
end
