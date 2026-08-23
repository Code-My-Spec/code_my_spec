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
      # What `HarnessScope` produces on every hook request: the id it routed on,
      # and the working copy that id names. The rewrite needs both — the cwd to
      # decide which server can reach the disk, the id to tell that server which
      # checkout it is about.
      %{scope: %{scope | cwd: "/tmp/proj", active_working_copy_id: Ecto.UUID.generate()}}
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
      assert command =~ "X-Harness-Id: #{scope.active_working_copy_id}"

      refute command =~ "X-Working-Dir",
             "the endpoint is chosen by cwd; the working copy is named by id"

      # A big suite outlives the Bash tool's ~2 min default kill.
      assert body["hookSpecificOutput"]["updatedInput"]["timeout"] == 600_000
    end

    # A heavy harness carries *both* a harness id and a cwd — `HarnessScope`
    # resolves the id and builds a scope with a cwd on it. So "has a harness id"
    # does not mean "is the light harness", and routing on it would send this to
    # the id-addressed endpoint only the light harness serves: a 404 on every
    # `mix test` an agent runs here.
    #
    # The question the rewrite is actually asking is whether whoever answers can
    # reach the disk, and `cwd` is what answers it.
    test "a harness id does not divert a run that has a working dir", %{scope: scope} do
      conn =
        build_post(scope, %{
          "tool_name" => "Bash",
          "tool_input" => %{"command" => "mix test"}
        })

      conn = PreToolUseController.handle(conn, conn.body_params)

      command =
        conn.resp_body
        |> Jason.decode!()
        |> get_in(["hookSpecificOutput", "updatedInput", "command"])

      assert command =~ "/api/analysis/run"
      assert command =~ "X-Harness-Id: #{scope.active_working_copy_id}"
      refute command =~ "/api/harnesses/"
    end

    # The light harness: a project, no disk. This used to produce no rewrite at
    # all, so the agent's suite ran unrecorded and the stop hook ran it again.
    test "with no working dir the run is addressed to the harness", %{scope: scope} do
      working_copy_id = Ecto.UUID.generate()
      scope = %{scope | cwd: nil, active_working_copy_id: working_copy_id}

      conn =
        build_post(scope, %{
          "tool_name" => "Bash",
          "tool_input" => %{"command" => "mix test"}
        })

      conn = PreToolUseController.handle(conn, conn.body_params)

      command =
        conn.resp_body
        |> Jason.decode!()
        |> get_in(["hookSpecificOutput", "updatedInput", "command"])

      assert command =~ "/api/harnesses/#{working_copy_id}/analysis/run"
      refute command =~ "X-Working-Dir"
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

    # Issue 0b54e827. Shell *before* mix never matched the anchor, so it was
    # already safe. Shell *after* mix was swallowed by the trailing `(.*)`:
    # the command got rewritten, the redirect and tail silently never ran, and
    # the shell tokens were persisted as the run's args — where the analysis
    # ledger showed [">", "/tmp/spex_604.txt", "2>&1;", "echo", "tail", ...].
    for {label, tail} <- [
          {"a redirect and a follow-on command",
           "> /tmp/out.txt 2>&1; echo exit=$?; tail -12 /tmp/out.txt"},
          {"a pipe", "| grep failure"},
          {"a chained command", "&& echo done"},
          {"command substitution", "--only $(cat /tmp/tag)"},
          {"a backgrounded run", "&"}
        ] do
      test "does not rewrite when the args are followed by #{label}", %{scope: scope} do
        command = "mix spex test/spex/some_spex.exs " <> unquote(tail)

        conn =
          build_post(scope, %{
            "tool_name" => "Bash",
            "tool_input" => %{"command" => command}
          })

        conn = PreToolUseController.handle(conn, conn.body_params)

        assert Jason.decode!(conn.resp_body) == %{},
               "expected pass-through so the shell runs as written, got a rewrite"
      end
    end

    # The curl carries no environment, so a rewrite drops the prefix. Only
    # MIX_ENV=test is safe to drop — it is already the default for both tasks.
    test "does not rewrite when an env prefix would change what runs", %{scope: scope} do
      conn =
        build_post(scope, %{
          "tool_name" => "Bash",
          "tool_input" => %{"command" => "MIX_ENV=cli_dev mix test test/my_test.exs"}
        })

      conn = PreToolUseController.handle(conn, conn.body_params)

      assert Jason.decode!(conn.resp_body) == %{}
    end

    test "does not rewrite when quoting makes the args ambiguous", %{scope: scope} do
      conn =
        build_post(scope, %{
          "tool_name" => "Bash",
          "tool_input" => %{"command" => ~s(mix test --only "unbalanced)}
        })

      conn = PreToolUseController.handle(conn, conn.body_params)

      assert Jason.decode!(conn.resp_body) == %{}
    end

    test "still rewrites a plain targeted run with flags", %{scope: scope} do
      conn =
        build_post(scope, %{
          "tool_name" => "Bash",
          "tool_input" => %{
            "command" => "mix test test/my_test.exs:42 --max-failures 1 --seed 0"
          }
        })

      conn = PreToolUseController.handle(conn, conn.body_params)

      command =
        conn.resp_body
        |> Jason.decode!()
        |> get_in(["hookSpecificOutput", "updatedInput", "command"])

      assert command =~ ~s("args":["test/my_test.exs:42","--max-failures","1","--seed","0"])
    end

    # A scope that can name the working copy no way at all. No `cwd`, so nothing
    # here can reach the disk, and no harness id, so nothing elsewhere can be
    # asked to. Running it unrewritten is the honest outcome — the run goes
    # unrecorded, and `no_rewrite/2` says so rather than returning the same `%{}`
    # that means "not a test command".
    test "does not rewrite when the scope can name no working copy", %{scope: scope} do
      conn =
        build_post(%{scope | cwd: nil, active_working_copy_id: nil}, %{
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
