defmodule CodeMySpecSpex.Story1171.Criterion2537Spex do
  @moduledoc """
  Story 1171 — I am told when work goes into the queue and never comes out.
  Criterion 2537 — A disconnected harness closes its unfinished run as abandoned.
  """

  use CodeMySpecSpex.Case, async: false

  alias CmsHarnessTest.LiveHarness
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A run whose harness disconnected ends abandoned rather than open forever",
    criterion: 2537 do
    scenario "team B's spex run is closed with its disconnect reason" do
      given_ "team B's harness has started a spex run", context do
        context = HarnessHooks.ensure_live_harness(context, feature: true)
        run = Fixtures.start_analysis_run(context.scope, "spex")
        :ok = HarnessHooks.start_analysis(context, run)
        {:ok, Map.put(context, :run_id, run.id)}
      end

      when_ "team B's harness disconnects and does not rejoin", context do
        :ok = LiveHarness.stop_serving(context.harness.root)
        {:ok, context}
      end

      then_ "the run is abandoned and names the disconnect", context do
        tool_context = %{scope: context.scope, current_scope: context.scope}

        eventually(
          fn ->
            assert {:ok, body} =
                     ToolLibrary.run("get_analysis_live", %{run_id: context.run_id}, tool_context)

            live = Jason.decode!(body)
            assert live["run_id"] == context.run_id
            assert live["source"] == "spex"
            assert live["status"] == "abandoned"
            assert live["reason"] =~ "disconnect"
          end,
          30_000
        )

        {:ok, context}
      end
    end
  end
end
