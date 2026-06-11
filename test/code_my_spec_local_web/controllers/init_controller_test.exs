defmodule CodeMySpecLocalWeb.InitControllerTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import Plug.Conn
  import Plug.Test

  alias CodeMySpecLocalWeb.InitController

  setup do
    scope = full_scope_fixture()
    %{scope: scope}
  end

  # Init lives on its own route (/api/skills/init, cwd-only scope) so it can run
  # before a project is linked. It handles only the bootstrap task and the `auth`
  # sub-flow — `sync` is its own skill now.

  describe "init" do
    test "auth subcommand returns the auth signal", %{scope: scope} do
      conn = build_post(scope, %{"arguments" => "auth"})
      conn = InitController.start(conn, conn.body_params)

      assert conn.status == 200
      assert %{"auth" => true} = Jason.decode!(conn.resp_body)
    end

    test "no subcommand runs init (not a routing error)", %{scope: scope} do
      conn = build_post(scope, %{"external_id" => "test-init"})
      conn = InitController.start(conn, conn.body_params)

      # Either succeeds or fails on init execution — but never a routing error.
      body = Jason.decode!(conn.resp_body)
      error = body["error"]
      refute is_binary(error) and error =~ "Unknown", "Init failed to route: #{inspect(body)}"
    end

    test "unknown subcommand returns 400 with available options", %{scope: scope} do
      conn = build_post(scope, %{"arguments" => "bogus"})
      conn = InitController.start(conn, conn.body_params)

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "Unknown subcommand"
      assert "auth" in body["available"]
    end
  end

  defp build_post(scope, body_params) do
    conn(:post, "/api/skills/init", Jason.encode!(body_params))
    |> put_req_header("content-type", "application/json")
    |> assign(:current_scope, scope)
    |> Map.put(:body_params, body_params)
  end
end
