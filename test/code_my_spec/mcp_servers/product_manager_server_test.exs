defmodule CodeMySpec.McpServers.ProductManagerServerTest do
  use ExUnit.Case
  doctest CodeMySpec.McpServers.ProductManagerServer
  alias CodeMySpec.McpServers.ProductManagerServer

  describe "server capabilities" do
    test "reports correct capabilities" do
      capabilities = ProductManagerServer.server_capabilities()

      assert Map.has_key?(capabilities, "tools")
    end

    test "has correct server info" do
      info = ProductManagerServer.server_info()

      assert info["name"] == "product-manager-server"
      assert info["version"] == "1.0.0"
    end
  end

  describe "components registration" do
    test "registers all expected components" do
      components = ProductManagerServer.__components__()
      assert components != []

      tools = ProductManagerServer.__components__(:tool)
      tool_names = Enum.map(tools, & &1.name)

      # Story CRUD
      assert "create_story" in tool_names
      assert "update_story" in tool_names
      assert "delete_story" in tool_names
      assert "get_story" in tool_names
      assert "list_stories" in tool_names
      assert "list_story_titles" in tool_names

      # Criteria
      assert "add_criterion" in tool_names
      assert "update_criterion" in tool_names
      assert "delete_criterion" in tool_names

      # Tags
      assert "list_project_tags" in tool_names
      assert "tag_stories" in tool_names

      # Sessions (interview, review, three amigos)
      assert "start_story_interview" in tool_names
      assert "start_story_review" in tool_names
      assert "start_three_amigos_session" in tool_names

      # Three Amigos workflow
      assert "add_rule" in tool_names
      assert "add_scenario" in tool_names
      assert "add_question" in tool_names
      assert "list_rules" in tool_names
      assert "list_questions" in tool_names
      assert "resolve_question" in tool_names
      assert "get_story_gherkin" in tool_names

      # Personas
      assert "link_persona_to_story" in tool_names
      assert "list_personas" in tool_names
      assert "create_persona" in tool_names

      # Issue triage
      assert "list_issues" in tool_names
      assert "accept_issue" in tool_names
      assert "dismiss_issue" in tool_names
      assert "resolve_issue" in tool_names
      assert "triage_issues" in tool_names
    end

    test "create_story has the expected required fields" do
      tools = ProductManagerServer.__components__(:tool)
      create_story_tool = Enum.find(tools, &(&1.name == "create_story"))

      assert create_story_tool != nil
      assert create_story_tool.description =~ "Creates a user story"

      schema = create_story_tool.input_schema
      required_fields = schema["required"]

      assert "title" in required_fields
      assert "description" in required_fields
      assert "acceptance_criteria" in required_fields
    end

    test "list_story_titles tool is registered" do
      tools = ProductManagerServer.__components__(:tool)
      tool = Enum.find(tools, &(&1.name == "list_story_titles"))

      assert tool != nil
      assert tool.description =~ "lightweight"
    end

    test "resources have proper URIs" do
      resources = ProductManagerServer.__components__(:resource)

      Enum.each(resources, fn resource ->
        assert resource.uri != nil
        assert is_binary(resource.uri)
        assert resource.description != nil
      end)
    end

    test "prompts have descriptions" do
      prompts = ProductManagerServer.__components__(:prompt)

      Enum.each(prompts, fn prompt ->
        assert prompt.description != nil
        assert prompt.description != ""
      end)
    end
  end

  describe "server interface" do
    test "server module has required MCP functions" do
      assert function_exported?(ProductManagerServer, :server_capabilities, 0)
      assert function_exported?(ProductManagerServer, :server_info, 0)
      assert function_exported?(ProductManagerServer, :handle_request, 2)
      assert function_exported?(ProductManagerServer, :supported_protocol_versions, 0)
    end

    test "protocol versions are supported" do
      versions = ProductManagerServer.supported_protocol_versions()
      assert is_list(versions)
      assert versions != []
      assert Enum.any?(versions, &String.contains?(&1, "2024"))
    end
  end
end
