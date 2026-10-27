defmodule CodeMySpecSpex.Story1141.Criterion2457Spex do
  @moduledoc """
  Story 1141 — I watch a test run as it happens.
  Criterion 2457 — A run whose harness stopped mid-run reads as orphaned.
  """

  use CodeMySpecSpex.Case, async: false

  alias CmsHarnessTest.LiveHarness
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.LiveRun
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A run whose harness stopped mid-run reads as orphaned", criterion: 2457 do
    scenario "the tool does not claim the abandoned run is still running" do
      given_ "an exunit run is running", context do
        {:ok, LiveRun.start(context)}
      end

      when_ "its harness goes away before the run ends and an agent calls get_analysis_live",
            context do
        :ok = LiveHarness.stop_serving(context.harness.root)
        tool_context = %{scope: context.scope, current_scope: context.scope}

        {:ok, body} =
          ToolLibrary.run("get_analysis_live", %{run_id: context.run_id}, tool_context)

        {:ok, Map.put(context, :first_live, Jason.decode!(body))}
      end

      then_ "the run reads as orphaned and not running", context do
        tool_context = %{scope: context.scope, current_scope: context.scope}

        eventually(
          fn ->
            assert {:ok, body} =
                     ToolLibrary.run("get_analysis_live", %{run_id: context.run_id}, tool_context)

            live = Jason.decode!(body)
            assert live["run_id"] == context.run_id
            assert live["orphaned"] == true
            refute live["status"] == "running"
          end,
          30_000
        )

        {:ok, context}
      end
    end
  end
end
