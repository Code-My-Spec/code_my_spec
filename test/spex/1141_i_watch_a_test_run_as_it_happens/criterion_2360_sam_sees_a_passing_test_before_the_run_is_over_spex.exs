defmodule CodeMySpecSpex.Story1141.Criterion2360Spex do
  @moduledoc """
  Story 1141 — I watch a test run as it happens.
  Criterion 2360 — Sam sees a passing test before the run is over.

  A test's result is shown as soon as that test finishes. The held test keeps
  the run going, so a pass shown here is one shown before the run is over.
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

  spex "Sam sees a passing test before the run is over", criterion: 2360 do
    scenario "the passing file reports while the held one still runs" do
      given_ "Sam's suite is running", context do
        {:ok, LiveRun.start(context)}
      end

      when_ "a test passes", context do
        {:ok, view, _html} = live(context.conn, LiveRun.path(context))
        {:ok, Map.put(context, :view, view)}
      end

      then_ "Sam sees it passed while the rest of the suite is still running", context do
        eventually(
          fn ->
            html = render(context.view)
            assert html =~ "adds up", "the passing test is not shown"
            assert html =~ ~r/passed/i
            assert html =~ ~r/running/i, "the run no longer reads as running"
          end,
          30_000
        )

        assert ClusteredProject.running?(context.os_pid)
        {:ok, context}
      end
    end
  end
end
