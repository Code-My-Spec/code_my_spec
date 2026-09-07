defmodule CodeMySpecLocalWeb.Antigravity.HooksControllerTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import Plug.Conn
  import Plug.Test

  alias CodeMySpec.FileEdits
  alias CodeMySpec.Sessions
  alias CodeMySpecLocalWeb.Antigravity.HooksController

  setup do
    scope = full_scope_fixture()
    %{scope: scope}
  end

  describe "pre_invocation/2" do
    test "creates a session on the first invocation", %{scope: scope} do
      conversation_id = "conv-#{System.unique_integer([:positive])}"

      conn =
        build_post(scope, "pre-invocation", %{
          "invocationNum" => 0,
          "conversationId" => conversation_id
        })

      conn = HooksController.pre_invocation(conn, conn.body_params)

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{}
      assert Sessions.get_by_external_id(scope, conversation_id)
    end

    test "does not create a session on later invocations", %{scope: scope} do
      conversation_id = "conv-#{System.unique_integer([:positive])}"

      conn =
        build_post(scope, "pre-invocation", %{
          "invocationNum" => 3,
          "conversationId" => conversation_id
        })

      conn = HooksController.pre_invocation(conn, conn.body_params)

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{}
      refute Sessions.get_by_external_id(scope, conversation_id)
    end

    test "responds {} when conversationId is missing", %{scope: scope} do
      conn = build_post(scope, "pre-invocation", %{"invocationNum" => 0})
      conn = HooksController.pre_invocation(conn, conn.body_params)

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{}
    end
  end

  describe "pre_tool_use/2" do
    test "defaults to ask, preserving the normal permission flow", %{scope: scope} do
      conn =
        build_post(scope, "pre-tool-use", %{
          "toolCall" => %{"name" => "view_file", "args" => %{"AbsolutePath" => "/tmp/x"}},
          "conversationId" => "conv-1"
        })

      conn = HooksController.pre_tool_use(conn, conn.body_params)

      assert Jason.decode!(conn.resp_body) == %{"decision" => "ask"}
    end

    test "tracks file edits from write tools", %{scope: scope} do
      conversation_id = "conv-#{System.unique_integer([:positive])}"

      conn =
        build_post(scope, "pre-tool-use", %{
          "toolCall" => %{
            "name" => "write_to_file",
            "args" => %{"TargetFile" => "/workspace/lib/foo.ex", "CodeContent" => "..."}
          },
          "conversationId" => conversation_id
        })

      conn = HooksController.pre_tool_use(conn, conn.body_params)

      assert Jason.decode!(conn.resp_body) == %{"decision" => "ask"}

      assert "/workspace/lib/foo.ex" in FileEdits.get_edited_files(conversation_id)
    end

    test "denies simple mix test with a curl redirect when a project is linked", %{scope: scope} do
      scope = %{scope | cwd: "/workspace/project"}

      conn =
        build_post(scope, "pre-tool-use", %{
          "toolCall" => %{
            "name" => "run_command",
            "args" => %{"CommandLine" => "mix test test/foo_test.exs", "Cwd" => "/workspace/project"}
          },
          "conversationId" => "conv-2"
        })

      conn = HooksController.pre_tool_use(conn, conn.body_params)

      body = Jason.decode!(conn.resp_body)
      assert body["decision"] == "deny"
      assert body["reason"] =~ "curl -sS -X POST"
      assert body["reason"] =~ "/api/analysis/run"
      assert body["reason"] =~ "exunit"
    end

    test "passes compound shell commands through untouched", %{scope: scope} do
      scope = %{scope | cwd: "/workspace/project"}

      conn =
        build_post(scope, "pre-tool-use", %{
          "toolCall" => %{
            "name" => "run_command",
            "args" => %{"CommandLine" => "cd apps/web && mix test"}
          },
          "conversationId" => "conv-3"
        })

      conn = HooksController.pre_tool_use(conn, conn.body_params)

      assert Jason.decode!(conn.resp_body) == %{"decision" => "ask"}
    end

    test "passes mix test through when no project is linked", %{scope: scope} do
      scope = %{scope | active_project_id: nil, active_project: nil}

      conn =
        build_post(scope, "pre-tool-use", %{
          "toolCall" => %{
            "name" => "run_command",
            "args" => %{"CommandLine" => "mix test"}
          },
          "conversationId" => "conv-4"
        })

      conn = HooksController.pre_tool_use(conn, conn.body_params)

      assert Jason.decode!(conn.resp_body) == %{"decision" => "ask"}
    end
  end

  describe "post_tool_use/2" do
    test "responds {} and touches session recency", %{scope: scope} do
      conversation_id = "conv-#{System.unique_integer([:positive])}"
      {:ok, _session} = Sessions.find_or_create_session(scope, conversation_id)

      conn =
        build_post(scope, "post-tool-use", %{
          "stepIdx" => 5,
          "error" => "",
          "conversationId" => conversation_id
        })

      conn = HooksController.post_tool_use(conn, conn.body_params)

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{}
    end

    test "responds {} for unknown conversations", %{scope: scope} do
      conn =
        build_post(scope, "post-tool-use", %{
          "stepIdx" => 5,
          "conversationId" => "conv-never-seen"
        })

      conn = HooksController.post_tool_use(conn, conn.body_params)

      assert Jason.decode!(conn.resp_body) == %{}
    end
  end

  describe "post_invocation/2" do
    test "responds {}", %{scope: scope} do
      conn = build_post(scope, "post-invocation", %{"invocationNum" => 1})
      conn = HooksController.post_invocation(conn, conn.body_params)

      assert Jason.decode!(conn.resp_body) == %{}
    end
  end

  describe "stop/2" do
    test "translates an allow into decision stop", %{scope: scope} do
      # No session for this conversation → StopController's no-session path
      # runs validation and (with nothing to validate in a fresh scope)
      # allows the stop, which must surface as Antigravity's stop decision.
      conn =
        build_post(scope, "stop", %{
          "conversationId" => "conv-unknown-#{System.unique_integer([:positive])}",
          "terminationReason" => "model_stop",
          "fullyIdle" => true
        })

      conn = HooksController.stop(conn, conn.body_params)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["decision"] in ["stop", "continue"]

      if body["decision"] == "continue" do
        assert is_binary(body["reason"]) and body["reason"] != ""
      end

      # Never leaks Claude Code dialect
      refute Map.has_key?(body, "systemMessage")
      refute Map.has_key?(body, "retrospective")
      refute body["decision"] == "block"
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp build_post(scope, path, body_params) do
    conn(:post, "/api/antigravity/hooks/#{path}", Jason.encode!(body_params))
    |> put_req_header("content-type", "application/json")
    |> assign(:current_scope, scope)
    |> Map.put(:body_params, body_params)
  end
end
