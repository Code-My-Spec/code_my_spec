defmodule CodeMySpecSpex.Story1144.Criterion2377Spex do
  @moduledoc """
  Story 1144 — Credo findings arrive as credo finds them.
  Criterion 2377 — Sam's credo run dies partway.

  A credo run that stops before checking every file reads as died, never as
  still in progress, and keeps the findings it had reported.
  """

  # Credo running for real on a live harness, watched while it runs.
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
  spex "Sam's credo run dies partway", criterion: 2377, fail_on_error_logs: false do
    scenario "credo is killed while the held check runs" do
      given_ "credo is running on Sam's project", context do
        {:ok, LiveRun.start_credo(context)}
      end

      when_ "it stops before checking every file", context do
        %{message: message} = ClusteredProject.finding()
        {:ok, view, _html} = live(context.conn, LiveRun.path(context))
        eventually(fn -> assert render(view) =~ message end, 30_000)
        :ok = ClusteredProject.kill(context.os_pid)
        {:ok, Map.put(context, :view, view)}
      end

      then_ "Sam sees the run died, and the findings it had reported", context do
        %{message: message} = ClusteredProject.finding()

        eventually(
          fn ->
            html = render(context.view)
            assert html =~ ~r/died/i, "the run does not read as died"
            refute html =~ ~r/\brunning\b/i, "a dead run still reads as running"
            assert html =~ message, "the findings reported before it died are gone"
          end,
          30_000
        )

        {:ok, context}
      end
    end
  end
end
