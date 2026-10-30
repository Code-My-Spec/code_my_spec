defmodule CodeMySpec.Telemetry.SetupTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.Cloudflare
  alias CodeMySpec.Provisioning.TelemetryStep

  test "default setup reaches the installer and does not publish a failed installation" do
    scope = full_scope_fixture()
    Environments.put(scope, "uat", %{ip: "203.0.113.10", host: "app.example.com"})
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
      setup_response(String.contains?(command, "MemAvailable:"), command)
    end

    assert {:error, "telemetry private network setup failed (exit 42)"} =
             TelemetryStep.run(scope, "uat", run: run)

    assert_received {:installation_command, command}
    assert command =~ "docker network inspect db_net"
    refute_received {:installation_command, _}

    assert {:error, :not_found} =
             ProjectSecrets.fetch_value(scope, "CLICKHOUSE_URL", environment: "uat")
  end

  test "insufficient memory refuses before starting containers or changing DNS" do
    scope = full_scope_fixture()
    Environments.put(scope, "uat", %{ip: "203.0.113.10", host: "app.example.com"})

    run = fn [command] ->
      send(self(), {:remote_command, command})
      {"FREE_KIB=1048576\nbroken-oaths-web\nmetric-flow-web", 0}
    end

    assert {:error, reason} = TelemetryStep.run(scope, "uat", run: run)
    assert reason =~ "2176 MiB"
    assert reason =~ "1024 MiB"
    assert reason =~ "broken-oaths-web"
    assert_received {:remote_command, command}
    assert command =~ "MemAvailable:"
    refute_received {:remote_command, _}

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

  defp setup_response(true, _command), do: {"FREE_KIB=4194304\nother-project-web", 0}

  defp setup_response(false, command),
    do: installation_response(String.contains?(command, "docker network inspect db_net"), command)

  defp installation_response(true, command) do
    send(self(), {:installation_command, command})
    {"sensitive remote output", 42}
  end

  defp installation_response(false, _command), do: {"", 0}
end
