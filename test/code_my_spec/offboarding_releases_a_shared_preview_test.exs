defmodule CodeMySpec.OffboardingReleasesASharedPreviewTest do
  @moduledoc """
  Offboarding a copy that was sharing a device's tunnel takes its preview
  down with it.

  Harness's condition on promoting the sharing feature at all: "this code
  decides what becomes publicly reachable, so it can't ship with its guards
  untested even if the spex come later." A copy's row is the only place that
  remembers it ever held a shared hostname — once `WorkingCopies.offboard/2`
  deletes it, there is nothing left to clean the ingress rule or the DNS
  record up with. So releasing the preview has to happen first, and a
  Cloudflare failure has to refuse the offboard loudly rather than delete the
  row anyway and leak a hostname nothing will ever remember to release.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Staffing
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Workspaces.PreviewAddress
  alias Req.Test

  setup do
    scope = full_scope_fixture()
    device = device_fixture(scope)
    tunnel_id = Ecto.UUID.generate()

    {:ok, main} = WorkingCopies.issue(scope, nil, label: "main", device: device)
    {:ok, main} = WorkingCopies.report_root(main, "/tmp/offboard_release_main")

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

    host = PreviewAddress.host(sibling.id)

    {:ok, sibling} =
      WorkingCopies.record_preview_tunnel(sibling, %{
        preview_url: PreviewAddress.url(sibling.id),
        preview_tunnel_id: tunnel_id,
        preview_tunnel_secret: "s3cret"
      })

    %{scope: scope, sibling: sibling, tunnel_id: tunnel_id, host: host}
  end

  test "removes the ingress rule and the DNS record before the row goes", %{
    scope: scope,
    sibling: sibling,
    host: host
  } do
    test_pid = self()

    Test.stub(CodeMySpec.Workspaces.PreviewTunnel, fn conn ->
      cloudflare_response(conn, test_pid, host, existing_dns_record: true)
    end)

    assert {:ok, _counts} = Staffing.offboard(scope, sibling)

    assert_receive {:put_config, ingress}

    refute Enum.any?(ingress, &(&1["hostname"] == host)),
           "the copy's own hostname was still in the tunnel's ingress after offboarding"

    assert_receive {:dns_deleted, _path}

    assert {:error, :not_found} = WorkingCopies.fetch(sibling.id)
  end

  test "a Cloudflare failure refuses the offboard and leaves the row in place", %{
    scope: scope,
    sibling: sibling,
    host: host
  } do
    Test.stub(CodeMySpec.Workspaces.PreviewTunnel, fn conn ->
      cloudflare_failure_response(conn, host)
    end)

    assert {:error, {:preview_not_released, _reason}} = Staffing.offboard(scope, sibling)

    assert {:ok, still_there} = WorkingCopies.fetch(sibling.id)

    assert still_there.preview_tunnel_id,
           "the row was cleared even though releasing the preview failed — the one " <>
             "record of a hostname Cloudflare may still be serving is now gone"
  end

  defp cloudflare_response(conn, test_pid, host, existing_dns_record: has_record?) do
    configurations_or_dns(
      String.contains?(conn.request_path, "/configurations"),
      conn,
      test_pid,
      host,
      has_record?
    )
  end

  defp configurations_or_dns(true, %{method: "GET"} = conn, _test_pid, host, _has_record?) do
    Test.json(conn, %{
      "success" => true,
      "errors" => [],
      "result" => %{"config" => %{"ingress" => [%{"hostname" => host, "service" => "x"}]}}
    })
  end

  defp configurations_or_dns(true, conn, test_pid, _host, _has_record?) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    send(test_pid, {:put_config, Jason.decode!(body)["config"]["ingress"]})
    Test.json(conn, %{"success" => true, "errors" => [], "result" => %{}})
  end

  defp configurations_or_dns(false, %{method: "GET"} = conn, _test_pid, _host, false) do
    Test.json(conn, %{"success" => true, "errors" => [], "result" => []})
  end

  defp configurations_or_dns(false, %{method: "GET"} = conn, _test_pid, _host, true) do
    Test.json(conn, %{
      "success" => true,
      "errors" => [],
      "result" => [%{"id" => "rec-shared-1", "content" => "irrelevant.cfargotunnel.com"}]
    })
  end

  defp configurations_or_dns(false, %{method: "DELETE"} = conn, test_pid, _host, _has_record?) do
    send(test_pid, {:dns_deleted, conn.request_path})
    Test.json(conn, %{"success" => true, "errors" => [], "result" => %{}})
  end

  # A tunnel with an unreachable Cloudflare account — every call fails the
  # same way, whether it is the ingress read, the ingress write or the DNS
  # lookup. What matters is that *some* step in `release/1` fails, not which.
  defp cloudflare_failure_response(conn, _host) do
    Test.json(conn, %{"success" => false, "errors" => [%{"code" => 1000, "message" => "down"}]})
  end
end
