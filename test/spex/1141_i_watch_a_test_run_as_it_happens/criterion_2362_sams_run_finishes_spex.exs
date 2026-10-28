defmodule CodeMySpecSpex.Story1141.Criterion2362Spex do
  @moduledoc """
  Story 1141 — I watch a test run as it happens.
  Criterion 2362 — Sam's run finishes.

  When the last test finishes the run reads as finished, with its totals:
  three tests, one failure.
  """

  # A real suite on a live harness, run while this scenario watches.
  use CodeMySpecSpex.Case, async: false

  import Phoenix.LiveViewTest

  alias CodeMySpec.Analysis.RunsRepository
  alias CmsHarnessTest.ClusteredProject
  alias CodeMySpecSpex.LiveRun
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Sam's run finishes", criterion: 2362 do
    scenario "the held test is released and the suite ends" do
      given_ "Sam's suite is running", context do
        {:ok, LiveRun.start(context)}
      end

      when_ "the last test finishes", context do
        {:ok, view, _html} = live(context.conn, LiveRun.path(context))
        :ok = ClusteredProject.release(context.harness.root)
        {:ok, Map.put(context, :view, view)}
      end

      then_ "Sam sees the run finished, with its totals", context do
        eventually(
          fn ->
            html = render(context.view)
            assert html =~ ~r/finished/i, "the run does not read as finished"
            assert html =~ ~r/3 tests/
            assert html =~ ~r/1 failure/
          end,
          60_000
        )

        {:ok, context}
      end
    end

    scenario "Sam reopens a finished run after its live state is gone" do
      given_ "a finished run recorded three tests and one failure", context do
        {:ok, run} =
          RunsRepository.start_run(context.scope, %{source: "spex", kind: :partial})

        {:ok, run} =
          RunsRepository.finish_run(run, :completed, %{stats: %{"tests" => 3, "failures" => 1}})

        assert CodeMySpec.Analysis.live_state(run.id) == nil
        {:ok, Map.put(context, :run, run)}
      end

      when_ "Sam opens the run later", context do
        {:ok, _view, html} =
          live(
            context.conn,
            "/app/projects/#{context.scope.active_project_id}/runs/#{context.run.id}"
          )

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the recorded totals are shown", context do
        assert context.html =~ "3 tests, 1 failure"
        {:ok, context}
      end
    end
  end
end
