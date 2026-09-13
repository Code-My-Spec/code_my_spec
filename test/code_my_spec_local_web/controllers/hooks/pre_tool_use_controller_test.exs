defmodule CodeMySpecLocalWeb.Hooks.PreToolUseControllerTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import Plug.Conn
  import Plug.Test

  alias CodeMySpec.Hooks.PreToolUse
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

      assert command =~ "sh -c"
      assert command =~ "curl -sS -o"
      assert command =~ "/api/analysis/run"
      assert command =~ ~s("source":"exunit")
      assert command =~ "test/my_test.exs"
      assert command =~ "X-Harness-Id: #{scope.active_working_copy_id}"

      refute command =~ "X-Working-Dir",
             "the working copy is named by id, never by a path on the wire"

      # A big suite outlives the Bash tool's ~2 min default kill.
      assert body["hookSpecificOutput"]["updatedInput"]["timeout"] == 600_000
    end

    # A heavy harness carries *both* a harness id and a cwd — `HarnessScope`
    # resolves the id and builds a scope with a cwd on it. So neither the id nor
    # the cwd says which router answers, and both were tried: routing on the id
    # sent a heavy harness at a route it does not serve, and routing on the cwd
    # sent every *proxied* copy at this router's bare route, which `cms_harness`
    # does not serve either — a 404 on every `mix test` an agent ran there
    # (`60b50e40`, reproduced against :4004).
    #
    # The question is which router answers on that port, and no property of the
    # scope knows it. The caller does: this controller is the packaged server, so
    # it says `:local`, and the answer stops depending on what a scope happens to
    # carry.
    test "the packaged server addresses its own route, whatever the scope carries",
         %{scope: scope} do
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

    # A scope with no disk still reaches this router, and this router still takes
    # the bare route — `cwd` was never what the endpoint depended on. This shape
    # used to produce no rewrite at all, so the agent's suite ran unrecorded and
    # the stop hook ran it again.
    test "and still does when the scope has no working dir", %{scope: scope} do
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

      assert command =~ "/api/analysis/run"
      assert command =~ "X-Harness-Id: #{working_copy_id}"
      refute command =~ "X-Working-Dir"
    end

    # The other half, and the one `60b50e40` is about: the same decision computed
    # on the cloud server is returned down the channel to `cms_harness`, whose
    # routes are all id-addressed. Asserted against `PreToolUse` directly because
    # there is no controller on that side — the channel is the caller.
    test "a proxied copy is addressed the way its harness routes", %{scope: scope} do
      answer =
        PreToolUse.decide(
          scope,
          %{"tool_name" => "Bash", "tool_input" => %{"command" => "mix test"}},
          4004,
          :harness
        )

      command = get_in(answer, ["hookSpecificOutput", "updatedInput", "command"])

      assert command =~ "/api/harnesses/#{scope.active_working_copy_id}/analysis/run"

      refute command =~ "X-Harness-Id",
             "the id is in the path already; a header would be a second place to disagree"
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
