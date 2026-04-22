defmodule CodeMySpecLocalWeb.Hooks.PreToolUseControllerTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import Plug.Conn
  import Plug.Test

  alias CodeMySpecLocalWeb.Hooks.PreToolUseController

  setup do
    scope = full_scope_fixture()
    %{scope: scope}
  end

  describe "MCP tool enrichment" do
    test "injects session_id into MCP tool inputs", %{scope: scope} do
      conn =
        build_post(scope, %{
          "tool_name" => "mcp__plugin_codemyspec_local__start_task",
          "tool_input" => %{"requirement_id" => "123"},
          "session_id" => "conv-abc-456"
        })

      conn = PreToolUseController.handle(conn, conn.body_params)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      hook_output = body["hookSpecificOutput"]

      assert hook_output["permissionDecision"] == "allow"
      assert hook_output["updatedInput"]["session_id"] == "conv-abc-456"
    end

    test "enriches evaluate_task tool too", %{scope: scope} do
      conn =
        build_post(scope, %{
          "tool_name" => "mcp__plugin_codemyspec_local__evaluate_task",
          "tool_input" => %{"task_id" => "task-789"},
          "session_id" => "conv-xyz"
        })

      conn = PreToolUseController.handle(conn, conn.body_params)

      body = Jason.decode!(conn.resp_body)
      assert body["hookSpecificOutput"]["updatedInput"]["session_id"] == "conv-xyz"
    end

    test "returns empty response when MCP tool has no session_id in payload", %{scope: scope} do
      conn =
        build_post(scope, %{
          "tool_name" => "mcp__plugin_codemyspec_local__start_task",
          "tool_input" => %{"requirement_id" => "123"}
          # No session_id in payload
        })

      conn = PreToolUseController.handle(conn, conn.body_params)

      body = Jason.decode!(conn.resp_body)
      assert body == %{}
    end

    test "does not enrich non-MCP tools", %{scope: scope} do
      conn =
        build_post(scope, %{
          "tool_name" => "Edit",
          "tool_input" => %{"file_path" => "/tmp/foo.ex"},
          "session_id" => "conv-should-not-inject"
        })

      conn = PreToolUseController.handle(conn, conn.body_params)

      body = Jason.decode!(conn.resp_body)
      assert body == %{}
    end
  end

  describe "mix test rewriting" do
    test "rewrites mix test to mix agent_test", %{scope: scope} do
      conn =
        build_post(scope, %{
          "tool_name" => "Bash",
          "tool_input" => %{"command" => "mix test test/my_test.exs"}
        })

      conn = PreToolUseController.handle(conn, conn.body_params)

      body = Jason.decode!(conn.resp_body)
      assert body["hookSpecificOutput"]["updatedInput"]["command"] =~ "mix agent_test"
      refute body["hookSpecificOutput"]["updatedInput"]["command"] =~ "mix test "
    end

    test "does not rewrite mix agent_test", %{scope: scope} do
      conn =
        build_post(scope, %{
          "tool_name" => "Bash",
          "tool_input" => %{"command" => "MIX_ENV=test mix agent_test test/my_test.exs"}
        })

      conn = PreToolUseController.handle(conn, conn.body_params)

      body = Jason.decode!(conn.resp_body)
      assert body == %{}
    end

    test "does not rewrite non-test bash commands", %{scope: scope} do
      conn =
        build_post(scope, %{
          "tool_name" => "Bash",
          "tool_input" => %{"command" => "mix compile"}
        })

      conn = PreToolUseController.handle(conn, conn.body_params)

      body = Jason.decode!(conn.resp_body)
      assert body == %{}
    end
  end

  defp build_post(scope, body_params) do
    conn(:post, "/api/hooks/pre-tool-use", Jason.encode!(body_params))
    |> put_req_header("content-type", "application/json")
    |> assign(:current_scope, scope)
    |> Map.put(:body_params, body_params)
  end
end
