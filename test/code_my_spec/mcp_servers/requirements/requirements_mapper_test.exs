defmodule CodeMySpec.McpServers.Requirements.RequirementsMapperTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Requirements.RequirementsMapper

  defmodule FakeTaskWithOrchestrate do
    def orchestrate(node) do
      "Spawn a @test-writer sub-agent to call `start_task` with requirement `#{node.name}` for #{node.entity_type} `#{node.entity_id}` (#{node.entity_name})"
    end
  end

  defmodule FakeTaskNoSummary do
  end

  defp build_node(overrides \\ %{}) do
    Map.merge(
      %{
        name: "spec_file",
        description: "Component specification file exists",
        satisfied: false,
        execution_type: :sub_agent,
        validation_type: :automatic,
        entity_type: "component",
        entity_id: "comp_1",
        entity_name: "Accounts",
        satisfied_by: FakeTaskWithOrchestrate,
        orchestrated_by: nil,
        parent_entity_id: nil,
        parent_entity_name: nil
      },
      overrides
    )
  end

  describe "list_requirements_response/1" do
    test "returns grouped markdown and structured data" do
      nodes = [
        build_node(),
        build_node(%{name: "write_tests", description: "Write ExUnit tests", satisfied: true})
      ]

      response = RequirementsMapper.list_requirements_response(nodes)

      assert response.type == :tool
      assert response.isError == false

      [%{"type" => "text", "text" => text}] = response.content
      assert text =~ "Component: Accounts"
      assert text =~ "[ ] **spec_file**"
      assert text =~ "[x] **write_tests**"
    end

    test "groups nodes by entity type and name" do
      nodes = [
        build_node(%{
          entity_type: "story",
          entity_name: "User Login",
          name: "acceptance_criteria"
        }),
        build_node(%{entity_type: "component", entity_name: "Auth", name: "implement"}),
        build_node(%{entity_type: "story", entity_name: "User Login", name: "qa_review"})
      ]

      response = RequirementsMapper.list_requirements_response(nodes)
      [%{"text" => text}] = response.content

      story_pos = :binary.match(text, "Story: User Login") |> elem(0)
      component_pos = :binary.match(text, "Component: Auth") |> elem(0)
      assert story_pos < component_pos
    end
  end

  describe "next_requirements_response/1" do
    test "standalone nodes grouped by satisfied_by" do
      nodes = [
        build_node(%{entity_name: "Accounts", entity_id: "comp_1"}),
        build_node(%{entity_name: "Users", entity_id: "comp_2"})
      ]

      response = RequirementsMapper.next_requirements_response(nodes)
      [%{"text" => text}] = response.content

      assert text =~ "### FakeTaskWithOrchestrate"
      assert text =~ "component `comp_1`"
      assert text =~ "component `comp_2`"
    end

    test "orchestrated nodes grouped under parent entity header" do
      nodes = [
        build_node(%{
          orchestrated_by: :develop_context,
          parent_entity_id: "ctx_1",
          parent_entity_name: "Todo.Accounts",
          satisfied_by: FakeTaskWithOrchestrate,
          name: "test_file",
          entity_id: "comp_1"
        }),
        build_node(%{
          orchestrated_by: :develop_context,
          parent_entity_id: "ctx_1",
          parent_entity_name: "Todo.Accounts",
          satisfied_by: FakeTaskNoSummary,
          name: "implementation_file",
          entity_id: "comp_1"
        })
      ]

      response = RequirementsMapper.next_requirements_response(nodes)
      [%{"text" => text}] = response.content

      # Header uses parent entity name
      assert text =~ "## Todo.Accounts"
      assert text =~ "Implement the child components in dependency order"

      # Nested satisfied_by groups
      assert text =~ "### FakeTaskWithOrchestrate"
      assert text =~ "### FakeTaskNoSummary"
    end

    test "standalone items are suppressed when orchestrated group is active" do
      orchestrated =
        build_node(%{
          orchestrated_by: :develop_context,
          parent_entity_id: "ctx_1",
          parent_entity_name: "Todo.Accounts",
          name: "test_file"
        })

      standalone = build_node(%{orchestrated_by: nil, name: "setup", entity_id: "proj_1"})

      response = RequirementsMapper.next_requirements_response([orchestrated, standalone])
      [%{"text" => text}] = response.content

      assert text =~ "## Todo.Accounts"
      assert text =~ "### FakeTaskWithOrchestrate"
      # Standalone items suppressed — agent focuses on orchestrated work
      refute text =~ "requirement `setup`"
    end

    test "standalone items render when no orchestrated group exists" do
      standalone = build_node(%{orchestrated_by: nil, name: "setup", entity_id: "proj_1"})

      response = RequirementsMapper.next_requirements_response([standalone])
      [%{"text" => text}] = response.content

      assert text =~ "requirement `setup`"
    end

    test "sub_agent nodes instruct to spawn a sub-agent" do
      nodes = [build_node(%{execution_type: :sub_agent})]

      response = RequirementsMapper.next_requirements_response(nodes)
      [%{"text" => text}] = response.content

      assert text =~ "Spawn a @test-writer sub-agent to call `start_task`"
      assert text =~ "component `comp_1` (Accounts)"
    end

    test "modules without orchestrate/1 fall back to generic start_task" do
      nodes = [build_node(%{satisfied_by: FakeTaskNoSummary})]

      response = RequirementsMapper.next_requirements_response(nodes)
      [%{"text" => text}] = response.content

      assert text =~ "requirement_name=`spec_file`"
      assert text =~ "entity_type=`component`"
      assert text =~ "entity_id=`comp_1`"
    end

    test "falls back to module name when no summary/0" do
      nodes = [build_node(%{satisfied_by: FakeTaskNoSummary})]

      response = RequirementsMapper.next_requirements_response(nodes)
      [%{"text" => text}] = response.content

      assert text =~ "### FakeTaskNoSummary"
    end
  end

  describe "error/1" do
    test "wraps binary reason" do
      response = RequirementsMapper.error("not found")

      assert response.isError == true
      [%{"text" => text}] = response.content
      assert text =~ "not found"
    end

    test "converts atom reason" do
      response = RequirementsMapper.error(:not_found)

      assert response.isError == true
      [%{"text" => text}] = response.content
      assert text =~ "not_found"
    end
  end

  describe "all_satisfied_response/0" do
    test "returns complete status" do
      response = RequirementsMapper.all_satisfied_response()

      [%{"text" => text}] = response.content
      assert text =~ "All requirements satisfied"
    end
  end
end
