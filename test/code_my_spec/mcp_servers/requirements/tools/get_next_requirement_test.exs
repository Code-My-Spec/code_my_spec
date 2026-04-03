defmodule CodeMySpec.McpServers.Requirements.Tools.GetNextRequirementTest do
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "execute/2" do
    test "returns the next actionable requirement" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = GetNextRequirement.execute(%{}, frame)

      refute response.isError
      content = response_text(response)

      # Should return the first actionable project-level requirement
      assert content =~ "Next Requirement:"
      assert content =~ "start_task"
    end

    test "returns init checklist when no project is linked" do
      frame = %Frame{assigns: %{}}

      assert {:reply, response, ^frame} = GetNextRequirement.execute(%{}, frame)
      refute response.isError
      assert is_nil(response.structured_content)
      assert response_text(response) =~ "Initialization"
      assert response_text(response) =~ "get_next_requirement"
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
