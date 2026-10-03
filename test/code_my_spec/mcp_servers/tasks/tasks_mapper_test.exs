defmodule CodeMySpec.McpServers.Tasks.TasksMapperTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Tasks.TasksMapper

  describe "evaluate_error_response/2" do
    test "names the missing header for :no_environment instead of the bare atom" do
      task = %{id: Ecto.UUID.generate(), session_type: CodeMySpec.AgentTasks.ArchitectureDesign}

      response = TasksMapper.evaluate_error_response(task, :no_environment)

      assert response.isError
      text = response_text(response)
      assert text =~ "X-Harness-Id"
      refute text =~ ":no_environment"
    end

    test "falls back to inspecting the reason for anything else" do
      task = %{id: Ecto.UUID.generate(), session_type: CodeMySpec.AgentTasks.ArchitectureDesign}

      response = TasksMapper.evaluate_error_response(task, :some_other_reason)

      assert response.isError
      assert response_text(response) =~ ":some_other_reason"
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
