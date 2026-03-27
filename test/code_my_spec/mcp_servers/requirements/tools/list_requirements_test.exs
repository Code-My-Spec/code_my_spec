defmodule CodeMySpec.McpServers.Requirements.Tools.ListRequirementsTest do
  use ExUnit.Case, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.RequirementsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "execute/2" do
    test "returns requirements grouped by entity with satisfaction status" do
      scope = full_scope_fixture()
      component = component_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      _satisfied = requirement_fixture(scope, component, %{name: "spec_file", satisfied: true})
      _unsatisfied = requirement_fixture(scope, component, %{name: "tests_passing", satisfied: false})

      assert {:reply, response, ^frame} = ListRequirements.execute(%{}, frame)

      refute response.isError
      content = response_text(response)

      assert content =~ "Project Requirements"
      assert content =~ "[x] **spec_file**"
      assert content =~ "[ ] **tests_passing**"

      data = extract_data(response)
      assert data["count"] == 2
      assert length(data["requirements"]) == 2

      names = Enum.map(data["requirements"], & &1["requirement_name"])
      assert "spec_file" in names
      assert "tests_passing" in names
    end

    test "returns empty list when no requirements exist" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ListRequirements.execute(%{}, frame)

      refute response.isError
      data = extract_data(response)
      assert data["count"] == 0
      assert data["requirements"] == []
    end

    test "returns error without valid scope" do
      frame = %Frame{assigns: %{}}

      assert {:reply, response, ^frame} = ListRequirements.execute(%{}, frame)
      assert response.isError
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end

  defp extract_data(%{structured_content: data}) when is_map(data) do
    Jason.decode!(Jason.encode!(data))
  end
end
