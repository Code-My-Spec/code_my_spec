defmodule CodeMySpec.McpServers.StoriesServerTest do
  use ExUnit.Case
  doctest CodeMySpec.McpServers.StoriesServer
  alias CodeMySpec.McpServers.StoriesServer

  describe "server capabilities" do
    test "reports correct capabilities" do
      capabilities = StoriesServer.server_capabilities()

      # Check that we have the three main capabilities
      assert Map.has_key?(capabilities, "tools")
    end

    test "has correct server info" do
      info = StoriesServer.server_info()

      assert info["name"] == "stories-server"
      assert info["version"] == "1.0.0"
    end
  end

  describe "components registration" do
    test "registers all expected components" do
      components = StoriesServer.__components__()

      # Should have components for tools, resources, and prompts
      assert components != []

      # Check we have tools
      tools = StoriesServer.__components__(:tool)
      tool_names = Enum.map(tools, & &1.name)

      assert "create_story" in tool_names
      assert "update_story" in tool_names
      assert "delete_story" in tool_names
      assert "get_story" in tool_names
      assert "list_stories" in tool_names
      assert "start_story_session" in tool_names
      assert "tag_stories" in tool_names
    end

    test "tools have proper input schemas" do
      tools = StoriesServer.__components__(:tool)
      create_story_tool = Enum.find(tools, &(&1.name == "create_story"))

      assert create_story_tool != nil
      assert create_story_tool.description =~ "Creates a user story"

      # Check schema has required fields
      schema = create_story_tool.input_schema
      required_fields = schema["required"]

      assert "title" in required_fields
      assert "description" in required_fields
      assert "acceptance_criteria" in required_fields
    end

    test "list_story_titles tool is registered" do
      tools = StoriesServer.__components__(:tool)
      tool = Enum.find(tools, &(&1.name == "list_story_titles"))

      assert tool != nil
      assert tool.description =~ "lightweight"
    end

    test "resources have proper URIs" do
      resources = StoriesServer.__components__(:resource)

      Enum.each(resources, fn resource ->
        assert resource.uri != nil
        assert is_binary(resource.uri)
        assert resource.description != nil
      end)
    end

    test "prompts have descriptions" do
      prompts = StoriesServer.__components__(:prompt)

      Enum.each(prompts, fn prompt ->
        assert prompt.description != nil
        assert prompt.description != ""
      end)
    end
  end

  describe "server interface" do
    test "server module has required MCP functions" do
      # Test that the server module is properly configured with MCP behavior
      assert function_exported?(StoriesServer, :server_capabilities, 0)
      assert function_exported?(StoriesServer, :server_info, 0)
      assert function_exported?(StoriesServer, :handle_request, 2)
      assert function_exported?(StoriesServer, :supported_protocol_versions, 0)
    end

    test "protocol versions are supported" do
      versions = StoriesServer.supported_protocol_versions()
      assert is_list(versions)
      assert versions != []
      # Should support recent MCP protocol versions
      assert Enum.any?(versions, &String.contains?(&1, "2024"))
    end
  end
end
