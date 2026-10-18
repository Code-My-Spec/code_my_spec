defmodule CodeMySpec.Telemetry.SetupTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.{Cloudflare, EnvironmentRepository}
  alias CodeMySpec.Provisioning.TelemetryStep

  test "default setup reaches the installer and does not publish a failed installation" do
    scope = full_scope_fixture()
    EnvironmentRepository.put(scope, "uat", %{ip: "203.0.113.10", host: "app.example.com"})
    previous = Application.fetch_env(:code_my_spec, Cloudflare)

    on_exit(fn -> restore_cloudflare_env(previous) end)

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"success" => true, "result" => cloudflare_zone_result(conn)})
      )
    end

    Application.put_env(:code_my_spec, Cloudflare, api_token: "test-token", plug: plug)

    run = fn [command] ->
      installation_response(String.contains?(command, "docker network inspect db_net"), command)
    end

    assert {:error, "telemetry private network setup failed (exit 42)"} =
             TelemetryStep.run(scope, "uat", run: run)

    assert_received {:installation_command, command}
    assert command =~ "docker network inspect db_net"
    refute_received {:installation_command, _}

    assert {:error, :not_found} =
             ProjectSecrets.fetch_value(scope, "CLICKHOUSE_URL", environment: "uat")
  end

  defp restore_cloudflare_env({:ok, value}),
    do: Application.put_env(:code_my_spec, Cloudflare, value)

  defp restore_cloudflare_env(:error), do: Application.delete_env(:code_my_spec, Cloudflare)

  defp cloudflare_zone_result(%{method: "GET", request_path: "/client/v4/zones"}) do
    [%{"id" => "z1", "name" => "example.com"}]
  end

  defp cloudflare_zone_result(%{method: "GET", request_path: "/client/v4/zones/z1/dns_records"}) do
    [
      %{
        "id" => "r1",
        "name" => "telemetry.app.example.com",
        "type" => "A",
        "content" => "203.0.113.10",
        "proxied" => false
      }
    ]
  end

  defp cloudflare_zone_result(conn) do
    flunk("unexpected DNS request: #{conn.method} #{conn.request_path}")
  end

  defp installation_response(true, command) do
    send(self(), {:installation_command, command})
    {"sensitive remote output", 42}
  end

  defp installation_response(false, _command), do: {"", 0}
end
