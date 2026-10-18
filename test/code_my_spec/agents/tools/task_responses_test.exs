defmodule CodeMySpec.Agents.Tools.TaskResponsesTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.Tools.TaskResponses, as: TasksMapper

  describe "evaluate_error_response/2" do
    test "names the missing header for :no_environment instead of the bare atom" do
      task = %{id: Ecto.UUID.generate(), session_type: CodeMySpec.AgentTasks.ArchitectureDesign}

      assert {:error, text} = TasksMapper.evaluate_error_response(task, :no_environment)
      assert text =~ "X-Harness-Id"
      refute text =~ ":no_environment"
    end

    test "falls back to inspecting the reason for anything else" do
      task = %{id: Ecto.UUID.generate(), session_type: CodeMySpec.AgentTasks.ArchitectureDesign}

      assert {:error, text} = TasksMapper.evaluate_error_response(task, :some_other_reason)
      assert text =~ ":some_other_reason"
    end
  end
end
