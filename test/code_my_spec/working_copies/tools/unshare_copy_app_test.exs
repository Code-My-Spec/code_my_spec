defmodule CodeMySpec.AppInstances.Tools.UnshareCopyAppTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary
  alias CodeMySpec.AppInstances

  alias Anubis.Server.Frame
  alias CodeMySpec.WorkingCopies
  alias Ecto.Adapters.SQL.Sandbox
  alias Req.Test

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "UnshareCopyApp tool" do
    test "drops a shared copy's ingress rule, DNS record and recorded address" do
      scope = full_scope_fixture()
      device = device_fixture(scope)

      # `TunnelIngressLock` is a node-wide Registry keyed on this literal —
      # a hardcoded id shared with another test file's tunnel would have the
      # two race for the same lock the moment both run concurrently, exactly
      # as if they were really the same tunnel. Unique per test is what
      # actually isolates them.
      tunnel_id = Ecto.UUID.generate()

      {:ok, main} = WorkingCopies.issue(scope, nil, label: "main", device: device)
      {:ok, main} = WorkingCopies.report_root(main, "/tmp/unshare_tool_main")
      {:ok, main_instance} = AppInstances.ensure_default(scope, main)

      {:ok, _main} =
        AppInstances.record_preview_tunnel(scope, main_instance, %{
          preview_url: "https://preview-#{main_instance.id}.astralbi.com",
          preview_tunnel_id: tunnel_id,
          preview_tunnel_secret: "s3cret"
        })

      {:ok, sibling} = WorkingCopies.issue(scope, nil, label: "worktree", device: device)
      {:ok, sibling} = WorkingCopies.report_root(sibling, "/tmp/unshare_tool_sibling")
      {:ok, sibling_instance} = AppInstances.ensure_default(scope, sibling)

      {:ok, sibling_instance} =
        AppInstances.record_status(scope, sibling_instance, %{
          status: "serving",
          url: "http://127.0.0.1:41234"
        })

      {:ok, sibling_instance} =
        AppInstances.record_preview_tunnel(scope, sibling_instance, %{
          preview_url: "https://preview-#{sibling_instance.id}.astralbi.com",
          preview_tunnel_id: tunnel_id,
          preview_tunnel_secret: "s3cret"
        })

      Test.stub(CodeMySpec.Workspaces.PreviewTunnel, &cloudflare_response(&1, tunnel_id))

      frame = %Frame{assigns: %{current_scope: %{scope | active_working_copy_id: sibling.id}}}

      response =
        ToolLibrary.run(
          "unshare_copy_app",
          %{},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)

      saved = AppInstances.get(scope, sibling_instance.id)
      assert saved.preview_tunnel_id == nil
      assert saved.preview_url == nil
    end

    test "succeeds as a no-op on a copy that was never shared" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "unshare_copy_app",
          %{},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
    end

    test "refuses when the call names no working copy of its own" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: %{scope | active_working_copy_id: nil}}}

      response =
        ToolLibrary.run(
          "unshare_copy_app",
          %{},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
    end
  end

  defp cloudflare_response(conn, tunnel_id) do
    configurations_or_dns(
      String.contains?(conn.request_path, "/configurations"),
      String.contains?(conn.request_path, "dns_records"),
      conn,
      tunnel_id
    )
  end

  defp configurations_or_dns(true, _dns?, %{method: "GET"} = conn, _tunnel_id) do
    Test.json(conn, %{
      "success" => true,
      "errors" => [],
      "result" => %{"config" => %{"ingress" => []}}
    })
  end

  defp configurations_or_dns(true, _dns?, conn, _tunnel_id) do
    Test.json(conn, %{"success" => true, "errors" => [], "result" => %{}})
  end

  defp configurations_or_dns(false, true, %{method: "GET"} = conn, tunnel_id) do
    Test.json(conn, %{
      "success" => true,
      "errors" => [],
      "result" => [%{"id" => "rec-1", "content" => tunnel_id <> ".cfargotunnel.com"}]
    })
  end

  defp configurations_or_dns(false, true, conn, _tunnel_id) do
    Test.json(conn, %{"success" => true, "errors" => [], "result" => %{}})
  end
end
