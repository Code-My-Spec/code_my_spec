defmodule CodeMySpecSpex.Story1141.Criterion2365Spex do
  @moduledoc """
  Story 1141 — I watch a test run as it happens.
  Criterion 2365 — Sam's failure is on the problems list mid-run.

  A failing test is a problem as soon as it fails: it is on Sam's problems
  list while the run is still going.
  """

  # A real suite on a live harness, run while this scenario watches.
  use CodeMySpecSpex.Case, async: false

  import Phoenix.LiveViewTest

  alias CmsHarnessTest.ClusteredProject
  alias CodeMySpecSpex.LiveRun
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Sam's failure is on the problems list mid-run", criterion: 2365 do
    scenario "the failure is listed while the held test still runs" do
      given_ "Sam's suite is running", context do
        {:ok, LiveRun.start(context)}
      end

      when_ "a test fails", context do
        {:ok, context}
      end

      then_ "that failure is on Sam's problems list before the run ends", context do
        %{message: message, file: file} = ClusteredProject.failure()

        eventually(
          fn ->
            {:ok, _view, html} = live(context.conn, LiveRun.problems_path(context))
            assert html =~ file and html =~ message, "the failure is not on the problems list"
          end,
          30_000
        )

        assert ClusteredProject.running?(context.os_pid), "the run ended before the check"
        {:ok, context}
      end
    end
  end
end
