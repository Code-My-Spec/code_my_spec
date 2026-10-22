defmodule CodeMySpecSpex.Story1141.Criterion2364Spex do
  @moduledoc """
  Story 1141 — I watch a test run as it happens.
  Criterion 2364 — Sam reads a failure while the run continues.

  A failure shows its message, file and line as soon as the test fails, while
  the held test still runs.
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

  spex "Sam reads a failure while the run continues", criterion: 2364 do
    scenario "the failing file reports while the held one still runs" do
      given_ "Sam's suite is running", context do
        {:ok, LiveRun.start(context)}
      end

      when_ "a test fails", context do
        {:ok, view, _html} = live(context.conn, LiveRun.path(context))
        {:ok, Map.put(context, :view, view)}
      end

      then_ "Sam sees its message, file and line while the remaining tests are still running",
            context do
        %{message: message, file: file, line: line} = ClusteredProject.failure()

        eventually(
          fn ->
            html = render(context.view)
            assert html =~ message, "the failure's message is not shown"
            assert html =~ "#{file}:#{line}", "the failure's file and line are not shown"
          end,
          30_000
        )

        assert ClusteredProject.running?(context.os_pid)
        {:ok, context}
      end
    end
  end
end
