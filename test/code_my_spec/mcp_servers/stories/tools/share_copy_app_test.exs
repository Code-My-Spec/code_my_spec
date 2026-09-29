defmodule CodeMySpec.McpServers.Stories.Tools.ShareCopyAppTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.ShareCopyApp
  alias CodeMySpec.WorkingCopies
  alias Ecto.Adapters.SQL.Sandbox
  alias Req.Test

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "ShareCopyApp tool" do
    test "shares a same-device sibling's tunnel for the caller's own serving copy" do
      scope = full_scope_fixture()
      device = device_fixture(scope)

      # `TunnelIngressLock` is a node-wide Registry keyed on this literal —
      # a hardcoded id shared with another test file's tunnel would have the
      # two race for the same lock the moment both run concurrently, exactly
      # as if they were really the same tunnel. Unique per test is what
      # actually isolates them.
      tunnel_id = Ecto.UUID.generate()

      {:ok, main} = WorkingCopies.issue(scope, nil, label: "main", device: device)
      {:ok, main} = WorkingCopies.report_root(main, "/tmp/share_tool_main")

      {:ok, _main} =
        WorkingCopies.record_preview_tunnel(main, %{
          preview_url: "https://preview-#{main.id}.astralbi.com",
          preview_tunnel_id: tunnel_id,
          preview_tunnel_secret: "s3cret"
        })

      {:ok, sibling} = WorkingCopies.issue(scope, nil, label: "worktree", device: device)

      {:ok, sibling} =
        WorkingCopies.record_app_status(sibling, %{
          status: "serving",
          url: "http://127.0.0.1:41234"
        })

      Test.stub(CodeMySpec.Workspaces.PreviewTunnel, &cloudflare_response/1)

      frame = %Frame{assigns: %{current_scope: %{scope | active_working_copy_id: sibling.id}}}

      assert {:reply, response, ^frame} = ShareCopyApp.execute(%{}, frame)
      refute response.isError

      {:ok, saved} = WorkingCopies.fetch(sibling.id)
      assert saved.preview_tunnel_id == tunnel_id
    end

    test "refuses when the caller's own copy is not serving" do
      scope = full_scope_fixture()

      {:ok, copy} =
        WorkingCopies.issue(scope, nil, label: "worktree", device: device_fixture(scope))

      frame = %Frame{assigns: %{current_scope: %{scope | active_working_copy_id: copy.id}}}

      assert {:reply, response, ^frame} = ShareCopyApp.execute(%{}, frame)
      assert response.isError
    end

    test "refuses when the call names no working copy of its own" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: %{scope | active_working_copy_id: nil}}}

      assert {:reply, response, ^frame} = ShareCopyApp.execute(%{}, frame)
      assert response.isError
    end
  end

  defp cloudflare_response(conn) do
    configurations_or_dns(
      String.contains?(conn.request_path, "/configurations"),
      conn
    )
  end

  defp configurations_or_dns(true, %{method: "GET"} = conn) do
    Test.json(conn, %{
      "success" => true,
      "errors" => [],
      "result" => %{"config" => %{"ingress" => []}}
    })
  end

  defp configurations_or_dns(true, conn) do
    Test.json(conn, %{"success" => true, "errors" => [], "result" => %{}})
  end

  defp configurations_or_dns(false, conn) do
    Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => "rec-1"}})
  end
end
