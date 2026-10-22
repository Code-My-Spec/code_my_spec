defmodule CodeMySpecSpex.Story1141.Criterion2363Spex do
  @moduledoc """
  Story 1141 — I watch a test run as it happens.
  Criterion 2363 — Sam's run dies partway.

  A run that stops before its last test reads as died, never as still in
  progress, and keeps what it had reported up to then.
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

  # A run that dies logs it: the harness reports a result the server refuses.
  spex "Sam's run dies partway", criterion: 2363, fail_on_error_logs: false do
    scenario "the run is killed while the held test runs" do
      given_ "Sam's suite is running", context do
        {:ok, LiveRun.start(context)}
      end

      when_ "the run stops before its last test, for any reason", context do
        {:ok, view, _html} = live(context.conn, LiveRun.path(context))
        eventually(fn -> assert render(view) =~ "adds up" end, 30_000)
        :ok = ClusteredProject.kill(context.os_pid)
        {:ok, Map.put(context, :view, view)}
      end

      then_ "Sam sees the run died, and the results it had reported up to then", context do
        eventually(
          fn ->
            html = render(context.view)
            assert html =~ ~r/died/i, "the run does not read as died"
            refute html =~ ~r/\brunning\b/i, "a dead run still reads as running"
            assert html =~ "adds up", "the results reported before it died are gone"
          end,
          30_000
        )

        {:ok, context}
      end
    end
  end
end
