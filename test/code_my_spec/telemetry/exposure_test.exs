defmodule CodeMySpec.Telemetry.ExposureTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.ClickHouse.Exposure

  defp discovery_response(<<"docker network inspect --format", _::binary>>),
    do: {"172.20.0.0/16\n", 0}

  defp discovery_response(<<"docker inspect --format", _::binary>>), do: {"172.21.0.2\n", 0}
  defp discovery_response(_command), do: {"", 0}

  test "writer access is restricted before the HTTPS route is registered" do
    run = fn [command] ->
      send(self(), {:command, command})
      discovery_response(command)
    end

    assert :ok = Exposure.publish(run, "telemetry.example.com")
    assert_received {:command, discovery}
    assert discovery =~ "db_net"
    assert_received {:command, restriction}
    assert restriction =~ "ALTER USER cms_writer HOST IP"
    assert_received {:command, network}
    assert network =~ "--internal cms-telemetry-read"
    assert_received {:command, address}
    assert address =~ "cms-clickhouse"
    assert_received {:command, route}
    assert route =~ "172.21.0.2:8123"
    assert route =~ "telemetry.example.com"
    assert route =~ "--tls --health-check-path /ping"
    refute_received {:command, _}
  end

  test "unknown ingest subnet stops exposure before any mutation" do
    run = fn [command] ->
      send(self(), {:command, command})
      {"unexpected subnet", 0}
    end

    assert {:error, "could not determine the telemetry ingest subnet"} =
             Exposure.publish(run, "telemetry.example.com")

    assert_received {:command, _}
    refute_received {:command, _}
  end

  defp proxy_failure_response(<<"docker network inspect --format", _::binary>>),
    do: {"172.20.0.0/16", 0}

  defp proxy_failure_response(<<"printf %s", _::binary>>), do: {"", 0}

  defp proxy_failure_response(command) do
    network_connect_response(String.contains?(command, "docker network connect"), command)
  end

  defp network_connect_response(true, _command), do: {"sensitive remote output", 7}

  defp network_connect_response(false, command),
    do: flunk("unexpected command after proxy failure: #{command}")

  test "proxy connection failure stops route registration and hides remote output" do
    run = fn [command] -> proxy_failure_response(command) end

    assert {:error, "telemetry HTTPS proxy network setup failed (exit 7)"} =
             Exposure.publish(run, "telemetry.example.com")
  end
end
