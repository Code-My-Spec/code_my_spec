defmodule CodeMySpecLocalWeb.Plugs.AntigravityWorkspaceTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias CodeMySpecLocalWeb.Plugs.AntigravityWorkspace

  test "lifts the first workspacePaths entry into the x-working-dir header" do
    conn =
      conn(:post, "/api/antigravity/hooks/stop")
      |> Map.put(:body_params, %{"workspacePaths" => ["/workspace/project", "/other"]})
      |> AntigravityWorkspace.call([])

    assert get_req_header(conn, "x-working-dir") == ["/workspace/project"]
  end

  test "an explicit x-working-dir header wins over the body" do
    conn =
      conn(:post, "/api/antigravity/hooks/stop")
      |> put_req_header("x-working-dir", "/explicit")
      |> Map.put(:body_params, %{"workspacePaths" => ["/workspace/project"]})
      |> AntigravityWorkspace.call([])

    assert get_req_header(conn, "x-working-dir") == ["/explicit"]
  end

  test "leaves the conn untouched when workspacePaths is absent or empty" do
    for body <- [%{}, %{"workspacePaths" => []}, %{"workspacePaths" => nil}] do
      conn =
        conn(:post, "/api/antigravity/hooks/stop")
        |> Map.put(:body_params, body)
        |> AntigravityWorkspace.call([])

      assert get_req_header(conn, "x-working-dir") == []
      refute conn.halted
    end
  end
end
