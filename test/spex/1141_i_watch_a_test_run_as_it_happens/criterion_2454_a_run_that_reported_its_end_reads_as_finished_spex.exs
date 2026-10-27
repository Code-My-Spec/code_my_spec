defmodule CodeMySpecSpex.Story1141.Criterion2454Spex do
  @moduledoc """
  Story 1141 — I watch a test run as it happens.
  Criterion 2454 — A run that reported its end reads as finished.
  """

  use CodeMySpecSpex.Case, async: false

  alias CmsHarnessTest.ClusteredProject
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.LiveRun
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A run that reported its end reads as finished", criterion: 2454 do
    scenario "the tool reports the suite end after its last test exits" do
      given_ "an exunit run has reported the end of its suite", context do
        context = LiveRun.start(context)
        :ok = ClusteredProject.release(context.harness.root)
        {:ok, context}
      end

      when_ "an agent calls get_analysis_live for it", context do
        tool_context = %{scope: context.scope, current_scope: context.scope}

        {:ok, body} =
          ToolLibrary.run("get_analysis_live", %{run_id: context.run_id}, tool_context)

        {:ok, Map.put(context, :first_live, Jason.decode!(body))}
      end

      then_ "live is finished", context do
        tool_context = %{scope: context.scope, current_scope: context.scope}

        eventually(
          fn ->
            assert {:ok, body} =
                     ToolLibrary.run("get_analysis_live", %{run_id: context.run_id}, tool_context)

            live = Jason.decode!(body)
            assert live["run_id"] == context.run_id
            assert live["live"] == "finished"
          end,
          30_000
        )

        {:ok, context}
      end
    end
  end
end
