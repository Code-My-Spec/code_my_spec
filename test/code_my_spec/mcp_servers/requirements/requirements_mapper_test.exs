defmodule CodeMySpec.McpServers.Requirements.RequirementsMapperTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Requirements.RequirementsMapper

  defmodule FakeTaskWithOrchestrate do
    def dispatch(node) do
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

    test "modules without dispatch/1 fall back to generic start_task" do
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

  describe "format_next_requirements/2 — project gates are never suppressed" do
    # Regression guard. An active orchestration group used to suppress *all*
    # standalone requirements, including project-level ones. That hid
    # architecture_designed and issues_triaged the moment any context had
    # component work in flight — so the agent was handed component code while
    # incoming issues sat untriaged. next_actionable/1 sorts project
    # requirements first; dropping them here made that invisible.
    test "a project requirement still shows when an orchestration group is active" do
      orchestrated =
        build_node(%{
          name: "implementation_file",
          entity_type: "component",
          entity_id: "comp_1",
          entity_name: "ProjectSecrets",
          orchestrated_by: :develop_context,
          parent_entity_id: "ctx_1",
          parent_entity_name: "CodeMySpec.ProjectSecrets"
        })

      project_gate =
        build_node(%{
          name: "issues_triaged",
          entity_type: "project",
          entity_id: "proj_1",
          entity_name: "Code My Spec",
          orchestrated_by: nil
        })

      text = RequirementsMapper.format_next_requirements([project_gate, orchestrated])

      assert text =~ "issues_triaged",
             "expected the project gate to survive an active orchestration group, got:\n#{text}"

      assert text =~ "CodeMySpec.ProjectSecrets",
             "expected the orchestration group to still be shown"
    end

    test "standalone story and component items are still suppressed by an orchestration group" do
      orchestrated =
        build_node(%{
          name: "implementation_file",
          orchestrated_by: :develop_context,
          parent_entity_id: "ctx_1",
          parent_entity_name: "CodeMySpec.ProjectSecrets"
        })

      unrelated_story =
        build_node(%{
          name: "bdd_specs_exist",
          entity_type: "story",
          entity_id: "999",
          entity_name: "Some unrelated story"
        })

      text = RequirementsMapper.format_next_requirements([unrelated_story, orchestrated])

      refute text =~ "bdd_specs_exist",
             "expected unrelated story work to stay suppressed so the active context keeps focus"

      assert text =~ "CodeMySpec.ProjectSecrets",
             "expected the orchestration group to be shown"
    end

    test "with no orchestration group everything standalone shows" do
      project_gate =
        build_node(%{name: "architecture_designed", entity_type: "project", entity_id: "proj_1"})

      story = build_node(%{name: "bdd_specs_exist", entity_type: "story", entity_id: "999"})

      text = RequirementsMapper.format_next_requirements([project_gate, story])

      assert text =~ "architecture_designed"
      assert text =~ "bdd_specs_exist"
    end
  end
end
