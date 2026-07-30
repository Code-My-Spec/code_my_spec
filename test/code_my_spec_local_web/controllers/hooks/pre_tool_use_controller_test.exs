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
    setup %{scope: scope} do
      # The analysis-API rewrite requires a linked project with a working dir.
      %{scope: %{scope | cwd: "/tmp/proj"}}
    end

    test "rewrites mix test into an analysis API curl", %{scope: scope} do
      conn =
        build_post(scope, %{
          "tool_name" => "Bash",
          "tool_input" => %{"command" => "mix test test/my_test.exs"}
        })

      conn = PreToolUseController.handle(conn, conn.body_params)

      body = Jason.decode!(conn.resp_body)
      command = body["hookSpecificOutput"]["updatedInput"]["command"]

      assert command =~ "curl -sS -X POST"
      assert command =~ "/api/analysis/run"
      assert command =~ ~s("source":"exunit")
      assert command =~ "test/my_test.exs"
      assert command =~ "X-Working-Dir: /tmp/proj"
      # A big suite outlives the Bash tool's ~2 min default kill.
      assert body["hookSpecificOutput"]["updatedInput"]["timeout"] == 600_000
    end

    test "rewrites mix spex with env prefix to the spex source", %{scope: scope} do
      conn =
        build_post(scope, %{
          "tool_name" => "Bash",
          "tool_input" => %{"command" => "MIX_ENV=test mix spex --stale"}
        })

      conn = PreToolUseController.handle(conn, conn.body_params)

      body = Jason.decode!(conn.resp_body)
      command = body["hookSpecificOutput"]["updatedInput"]["command"]

      assert command =~ ~s("source":"spex")
      assert command =~ "--stale"
    end

    test "does not rewrite compound shell commands", %{scope: scope} do
      conn =
        build_post(scope, %{
          "tool_name" => "Bash",
          "tool_input" => %{"command" => "cd sub && mix test"}
        })

      conn = PreToolUseController.handle(conn, conn.body_params)

      body = Jason.decode!(conn.resp_body)
      assert body == %{}
    end

    # The pre-existing compound test above covers a *leading* compound
    # (`cd sub && mix test`), which the old pattern already rejected because it
    # anchored `mix` to the start. The gap was everything trailing: `(.*)` with
    # `/s` ran to the end of the command, so a pipe or a redirect was captured
    # as arguments to mix and handed to the analysis API. The agent then got a
    # run summary where it had asked for grep output, with nothing saying its
    # command had been rewritten — six retries in four minutes, in one run.
    for {label, command} <- [
          {"a pipe", "mix spex test/spex/a_spex.exs --verbose 2>&1 | grep -oE 'foo'"},
          {"a redirect and a second command", "mix spex a_spex.exs > /tmp/c.txt 2>&1; grep -o x /tmp/c.txt"},
          {"stderr redirection", "mix test 2>&1 | tail -30"},
          {"command substitution", "mix test $(cat files.txt)"}
        ] do
      test "does not rewrite a command containing #{label}", %{scope: scope} do
        conn =
          build_post(scope, %{
            "tool_name" => "Bash",
            "tool_input" => %{"command" => unquote(command)}
          })

        conn = PreToolUseController.handle(conn, conn.body_params)

        assert Jason.decode!(conn.resp_body) == %{},
               "expected #{unquote(command)} to pass through to the shell unmodified"
      end
    end

    test "does not rewrite without a working dir on the scope", %{scope: scope} do
      conn =
        build_post(%{scope | cwd: nil}, %{
          "tool_name" => "Bash",
          "tool_input" => %{"command" => "mix test"}
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
