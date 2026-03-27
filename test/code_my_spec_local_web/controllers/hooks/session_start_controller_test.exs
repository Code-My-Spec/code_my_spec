defmodule CodeMySpecLocalWeb.Hooks.SessionStartControllerTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import Plug.Conn
  import Plug.Test

  alias CodeMySpecLocalWeb.Hooks.SessionStartController
  alias CodeMySpec.Sessions

  setup do
    scope = full_scope_fixture()
    %{scope: scope}
  end

  describe "handle/2" do
    test "creates a new session and returns session_id and status", %{scope: scope} do
      session_id = "session-#{System.unique_integer([:positive])}"

      conn = build_post(scope, %{"session_id" => session_id})
      conn = SessionStartController.handle(conn, %{})

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["session_id"]
      assert body["status"]
    end

    test "returns existing session when session_id already exists", %{scope: scope} do
      session_id = "session-#{System.unique_integer([:positive])}"
      {:ok, existing} = Sessions.find_or_create_session(scope, session_id)

      conn = build_post(scope, %{"session_id" => session_id})
      conn = SessionStartController.handle(conn, %{})

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["session_id"] == existing.id
    end

    test "returns 400 when session_id is missing", %{scope: scope} do
      conn = build_post(scope, %{})
      conn = SessionStartController.handle(conn, %{})

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "session_id is required"
    end

    test "returns 400 when session_id is empty string", %{scope: scope} do
      conn = build_post(scope, %{"session_id" => ""})
      conn = SessionStartController.handle(conn, %{})

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "session_id is required"
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp build_post(scope, body_params) do
    conn(:post, "/api/hooks/session-start", Jason.encode!(body_params))
    |> put_req_header("content-type", "application/json")
    |> assign(:current_scope, scope)
    |> Map.put(:body_params, body_params)
  end
end
