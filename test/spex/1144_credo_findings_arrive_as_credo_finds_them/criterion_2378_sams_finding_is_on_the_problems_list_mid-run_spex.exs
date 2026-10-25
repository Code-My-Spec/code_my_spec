defmodule CodeMySpecSpex.Story1144.Criterion2378Spex do
  @moduledoc """
  Story 1144 — Credo findings arrive as credo finds them.
  Criterion 2378 — Sam's finding is on the problems list mid-run.

  A finding is a problem as soon as credo reports it: it is on Sam's problems
  list while credo is still checking.
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

  spex "Sam's finding is on the problems list mid-run", criterion: 2378 do
    scenario "the finding is listed while the held check still runs" do
      given_ "credo is running on Sam's project", context do
        {:ok, LiveRun.start_credo(context)}
      end

      when_ "it reports a finding", context do
        {:ok, context}
      end

      then_ "that finding is on Sam's problems list before the run ends", context do
        %{message: message, file: file} = ClusteredProject.finding()

        eventually(
          fn ->
            {:ok, _view, html} = live(context.conn, LiveRun.problems_path(context))
            assert html =~ file and html =~ message, "the finding is not on the problems list"
          end,
          30_000
        )

        assert ClusteredProject.running?(context.os_pid), "credo ended before the check"
        {:ok, context}
      end
    end
  end
end
