defmodule CodeMySpecSpex.Story1144.Criterion2375Spex do
  @moduledoc """
  Story 1144 — Credo findings arrive as credo finds them.
  Criterion 2375 — Sam sees a finding mid-run.

  A finding shows on the run's page as soon as credo reports it, while credo
  is still checking.
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

  spex "Sam sees a finding mid-run", criterion: 2375 do
    scenario "the finding shows while the held check still runs" do
      given_ "credo is running on Sam's project", context do
        {:ok, LiveRun.start_credo(context)}
      end

      when_ "it reports a finding", context do
        {:ok, view, _html} = live(context.conn, LiveRun.path(context))
        {:ok, Map.put(context, :view, view)}
      end

      then_ "Sam sees it while credo is still running", context do
        %{message: message, file: file} = ClusteredProject.finding()

        eventually(
          fn ->
            html = render(context.view)
            assert html =~ message, "the finding is not on the run's page"
            assert html =~ file
            assert html =~ ~r/\brunning\b/i, "the run no longer reads as running"
          end,
          30_000
        )

        assert ClusteredProject.running?(context.os_pid), "credo ended before the check"
        {:ok, context}
      end
    end
  end
end
