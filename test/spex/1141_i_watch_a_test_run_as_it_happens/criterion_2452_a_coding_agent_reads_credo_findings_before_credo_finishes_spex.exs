defmodule CodeMySpecSpex.Story1141.Criterion2452Spex do
  @moduledoc """
  Story 1141 — I watch a test run as it happens.
  Criterion 2452 — A coding agent reads Credo findings before Credo finishes.
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

  spex "A coding agent reads Credo findings before Credo finishes", criterion: 2452 do
    scenario "the finding is available through the tool while the check remains held" do
      given_ "a credo run is running on the coding agent's working copy", context do
        {:ok, LiveRun.start_credo(context)}
      end

      given_ "credo has reported one finding so far", context do
        {:ok, context}
      end

      when_ "the agent calls get_analysis_live with source credo", context do
        tool_context = %{scope: context.scope, current_scope: context.scope}
        {:ok, body} = ToolLibrary.run("get_analysis_live", %{source: "credo"}, tool_context)
        {:ok, Map.put(context, :first_live, Jason.decode!(body))}
      end

      then_ "that finding is listed while the run is still running", context do
        %{message: message, file: file, line: line} = ClusteredProject.finding()
        tool_context = %{scope: context.scope, current_scope: context.scope}

        eventually(
          fn ->
            assert {:ok, body} =
                     ToolLibrary.run("get_analysis_live", %{source: "credo"}, tool_context)

            live = Jason.decode!(body)
            assert live["run_id"] == context.run_id
            assert live["source"] == "credo"
            assert live["status"] == "running"
            assert live["live"] == "streaming"

            assert Enum.any?(live["findings"], fn finding ->
                     finding["file"] == file and finding["line"] == line and
                       String.contains?(finding["message"], message)
                   end)
          end,
          30_000
        )

        assert ClusteredProject.running?(context.os_pid)
        {:ok, context}
      end
    end
  end
end
