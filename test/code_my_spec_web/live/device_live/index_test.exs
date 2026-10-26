defmodule CodeMySpecWeb.DeviceLive.IndexTest do
  use CodeMySpecTest.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.AccountSecrets
  alias CodeMySpec.Devices
  alias CodeMySpec.Provisioning.Hetzner

  setup [:register_log_in_setup_account, :setup_active_project]

  test "one navigation entry includes local and provider machines without duplicating an enrolled server",
       %{
         conn: conn,
         scope: scope,
         project: project
       } do
    local = device_fixture(scope, %{hostname: "local-workstation"})
    {:ok, remote} = Devices.link_provider_machine(scope, %{name: "production-box", id: 123})
    {:ok, _, _token} = Devices.enroll_existing_device(scope, remote.id)
    AccountSecrets.put_value(scope, "hetzner_api_token", "test-token")

    Req.Test.stub(Hetzner, &provider_response/1)

    base = "/app/projects/#{project.id}/console/devices"
    {:ok, view, _} = live(conn, base)
    assert has_element?(view, "[data-test=console-nav-devices].menu-active", "Devices")
    refute has_element?(view, "[data-test=console-nav-servers]")
    refute has_element?(view, "[data-test=console-nav-dev-boxes]")
    assert has_element?(view, "[data-test=device][data-device-id='#{local.id}']")
    refute has_element?(view, "[data-test=device][data-device-id='#{remote.id}']")
    assert has_element?(view, "[data-test=server][data-name=production-box]")
    assert has_element?(view, "[data-test=open-server][href='#{base}/#{remote.id}']")
    assert has_element?(view, "[data-test=add-dev-box]")
    assert has_element?(view, "[data-test=server]", "Harness")
  end

  defp provider_response(%{request_path: "/v1/servers"} = conn) do
    provider_json(conn, %{
      "servers" => [
        %{
          "id" => 123,
          "name" => "production-box",
          "status" => "running",
          "public_net" => %{"ipv4" => %{"ip" => "192.0.2.1"}},
          "server_type" => %{"name" => "cpx11"}
        }
      ]
    })
  end

  defp provider_response(conn), do: provider_json(conn, %{})

  defp provider_json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end
