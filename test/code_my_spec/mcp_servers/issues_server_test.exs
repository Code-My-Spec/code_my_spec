defmodule CodeMySpec.McpServers.IssuesServerTest do
  use ExUnit.Case
  alias CodeMySpec.McpServers.IssuesServer

  describe "server capabilities" do
    test "reports correct capabilities" do
      capabilities = IssuesServer.server_capabilities()
      assert Map.has_key?(capabilities, "tools")
    end

    test "has correct server info" do
      info = IssuesServer.server_info()
      assert info["name"] == "issues-server"
      assert info["version"] == "1.0.0"
    end
  end

  describe "components registration" do
    test "registers all expected tools" do
      tools = IssuesServer.__components__(:tool)
      tool_names = Enum.map(tools, & &1.name)

      assert "create_issue" in tool_names
      assert "list_issues" in tool_names
      assert "get_issue" in tool_names
      assert "accept_issue" in tool_names
      assert "dismiss_issue" in tool_names
      assert "resolve_issue" in tool_names
    end

    test "create_issue tool has proper input schema" do
      tools = IssuesServer.__components__(:tool)
      tool = Enum.find(tools, &(&1.name == "create_issue"))

      assert tool != nil
      schema = tool.input_schema
      required = schema["required"]

      assert "title" in required
      assert "severity" in required
      assert "description" in required
    end
  end
end
