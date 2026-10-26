defmodule CodeMySpecSpex.Story1141.Criterion2450Spex do
  @moduledoc """
  Story 1141 — I watch a test run as it happens.
  Criterion 2450 — A coding agent reads a failure from a running exunit run.
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

  spex "A coding agent reads a failure from a running exunit run", criterion: 2450 do
    scenario "live analysis names the failed test while another file is running" do
      given_ "an exunit run has reported a failure while another test remains running", context do
        {:ok, LiveRun.start(context)}
      end

      when_ "the agent calls get_analysis_live with that run's id", context do
        tool_context = %{scope: context.scope, current_scope: context.scope}

        {:ok, body} =
          ToolLibrary.run("get_analysis_live", %{run_id: context.run_id}, tool_context)

        {:ok, Map.merge(context, %{tool_context: tool_context, first_live: Jason.decode!(body)})}
      end

      then_ "the status is running and live is streaming, with one failure and the current files",
            context do
        %{message: message, file: file, line: line} = ClusteredProject.failure()

        eventually(
          fn ->
            assert {:ok, body} =
                     ToolLibrary.run(
                       "get_analysis_live",
                       %{run_id: context.run_id},
                       context.tool_context
                     )

            live = Jason.decode!(body)
            assert live["run_id"] == context.run_id
            assert live["source"] == "exunit"
            assert live["status"] == "running"
            assert live["live"] == "streaming"
            assert live["tests"]["failed"] == 1

            assert Enum.any?(live["failures"], fn failure ->
                     failure["file"] == file and
                       (failure["failure_line"] || failure["line"]) == line and
                       String.contains?(failure["message"], message)
                   end)

            assert live["running_files"] != []
          end,
          30_000
        )

        assert ClusteredProject.running?(context.os_pid)
        {:ok, context}
      end
    end
  end
end
