defmodule CodeMySpec.Architecture.Tools.ResponsesTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Architecture.Tools.Responses, as: ArchitectureMapper
  alias Ecto.Adapters.SQL.Sandbox
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "architecture_summary_response/1" do
    test "returns structured summary" do
      summary = %{
        context_count: 5,
        component_count: 42,
        dependency_count: 18,
        orphaned_count: 1,
        max_depth: 4,
        circular_dependencies: false
      }

      response = ArchitectureMapper.architecture_summary_response(summary)

      assert {:ok, json_text} = response

      data = Jason.decode!(json_text)

      assert data["context_count"] == 5
      assert data["component_count"] == 42
      assert data["circular_dependencies"] == false
    end
  end

  describe "component_impact_response/1" do
    test "returns impact analysis" do
      scope = full_scope_fixture()

      component = %Component{
        id: "uuid-main",
        name: "Main",
        type: "context",
        module_name: "MyApp.Main",
        project_id: scope.active_project_id
      }

      dependent = %Component{
        id: "uuid-dep",
        name: "Dependent",
        type: "module",
        module_name: "MyApp.Dependent",
        project_id: scope.active_project_id
      }

      impact = %{
        component: component,
        direct_dependents: [dependent],
        transitive_dependents: [],
        affected_contexts: []
      }

      response = ArchitectureMapper.component_impact_response(impact)

      assert {:ok, json_text} = response

      data = Jason.decode!(json_text)

      assert data["component"]["module_name"] == "MyApp.Main"
      assert length(data["direct_dependents"]) == 1
      assert Enum.at(data["direct_dependents"], 0)["module_name"] == "MyApp.Dependent"
    end
  end

  describe "validation_result_response/1" do
    test "returns success for valid graph" do
      response = ArchitectureMapper.validation_result_response(:ok)

      assert {:ok, json_text} = response

      data = Jason.decode!(json_text)

      assert data["valid"] == true
      assert data["message"] == "No circular dependencies detected"
    end

    test "returns error for circular dependencies" do
      cycles = [
        %{
          path: ["A", "B"],
          components: [
            %{id: "id1", name: "A", type: "context", module_name: "MyApp.A"},
            %{id: "id2", name: "B", type: "context", module_name: "MyApp.B"}
          ]
        }
      ]

      response = ArchitectureMapper.validation_result_response({:error, cycles})

      assert {:ok, json_text} = response

      data = Jason.decode!(json_text)

      assert data["valid"] == false
      assert data["message"] == "Circular dependencies detected"
      assert is_list(data["cycles"])
      assert length(data["cycles"]) == 1

      cycle = List.first(data["cycles"])
      assert cycle["path"] == ["A", "B"]
      assert length(cycle["components"]) == 2
    end
  end

  describe "error/1" do
    test "handles atom errors" do
      response = ArchitectureMapper.error(:invalid_scope)

      assert {_, _} = response
      assert match?({:error, _}, response)
    end

    test "handles string errors" do
      response = ArchitectureMapper.error("Something went wrong")

      assert {_, _} = response
      assert match?({:error, _}, response)
    end

    test "handles changeset errors" do
      changeset =
        %Component{}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:name, "can't be blank")

      response = ArchitectureMapper.error(changeset)

      assert {_, _} = response
      assert match?({:error, _}, response)
    end
  end

  describe "prompt_response/1" do
    test "returns text prompt" do
      prompt = "This is a test prompt for the agent"

      response = ArchitectureMapper.prompt_response(prompt)

      assert {:ok, ^prompt} = response
    end
  end

  describe "component_view_response/1" do
    test "returns markdown view" do
      markdown = """
      # MyApp.Users

      User management context

      ## Dependencies

      - MyApp.Accounts
      """

      response = ArchitectureMapper.component_view_response(markdown)

      assert {:ok, ^markdown} = response
    end
  end
end
