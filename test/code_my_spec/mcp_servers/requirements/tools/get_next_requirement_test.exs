defmodule CodeMySpec.McpServers.Requirements.Tools.GetNextRequirementTest do
  use ExUnit.Case, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.RequirementsFixtures
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
      component = component_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      _satisfied = requirement_fixture(scope, component, %{name: "spec_file", satisfied: true})

      _actionable =
        requirement_fixture(scope, component, %{
          name: "tests_passing",
          satisfied: false,
          satisfied_by: CodeMySpec.AgentTasks.ContextSpec
        })

      assert {:reply, response, ^frame} = GetNextRequirement.execute(%{}, frame)

      refute response.isError
      content = response_text(response)

      assert content =~ "Next Requirement: tests_passing"
      assert content =~ "start_task"

      data = extract_data(response)
      assert data["requirement_name"] == "tests_passing"
      assert data["requirement_id"]
    end

    test "returns all-satisfied when no actionable requirements exist" do
      scope = full_scope_fixture()
      component = component_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      # Only satisfied requirements
      _satisfied = requirement_fixture(scope, component, %{name: "spec_file", satisfied: true})

      assert {:reply, response, ^frame} = GetNextRequirement.execute(%{}, frame)

      refute response.isError
      content = response_text(response)
      assert content =~ "All requirements satisfied"
    end

    test "skips requirements without satisfied_by" do
      scope = full_scope_fixture()
      component = component_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      # Unsatisfied but no satisfied_by — meta-requirement, not actionable
      _meta = requirement_fixture(scope, component, %{name: "deps_satisfied", satisfied: false, satisfied_by: nil})

      assert {:reply, response, ^frame} = GetNextRequirement.execute(%{}, frame)

      refute response.isError
      content = response_text(response)
      assert content =~ "All requirements satisfied"
    end

    test "returns init checklist when no project is linked" do
      frame = %Frame{assigns: %{}}

      assert {:reply, response, ^frame} = GetNextRequirement.execute(%{}, frame)
      refute response.isError
      assert response.structured_content == %{status: :init_required}
      assert response_text(response) =~ "Initialization"
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
