defmodule CodeMySpec.Provisioning.ClickHouse.Exposure do
  @moduledoc false

  alias CodeMySpec.Provisioning.ClickHouse.{Runtime, Schema}

  @network "cms-telemetry-read"

  def publish(run, host) do
    with :ok <- Schema.restrict_writer(run),
         :ok <- connect_proxy(run),
         {:ok, address} <- database_address(run),
         :ok <- route(run, host, address) do
      :ok
    end
  end

  defp connect_proxy(run) do
    command = """
    set -eu
    test "$(docker inspect --format '{{.State.Running}}' kamal-proxy)" = true
    docker network inspect #{@network} >/dev/null 2>&1 || docker network create --internal #{@network} >/dev/null
    for container in cms-clickhouse kamal-proxy; do
      connected=$(docker inspect --format '{{if index .NetworkSettings.Networks "#{@network}"}}yes{{end}}' "$container")
      if [ "$connected" != yes ]; then
        docker network connect #{@network} "$container"
      fi
    done
    """

    Runtime.execute(run, command, "HTTPS proxy network setup")
  end

  defp database_address(run) do
    template = ~s|{{(index .NetworkSettings.Networks "#{@network}").IPAddress}}|
    command = "docker inspect --format #{Runtime.shell_quote(template)} cms-clickhouse"

    with {:ok, address} <- Runtime.capture(run, command, "HTTPS upstream discovery"),
         {:ok, parsed} <- :inet.parse_address(String.to_charlist(address)),
         true <- tuple_size(parsed) == 4 do
      {:ok, address}
    else
      _ -> {:error, "could not determine the telemetry HTTPS upstream address"}
    end
  end

  defp route(run, host, address) do
    service = "cms-telemetry-" <> String.slice(Runtime.fingerprint(host), 0, 16)

    command =
      "docker exec kamal-proxy kamal-proxy deploy #{Runtime.shell_quote(service)} " <>
        "--target #{Runtime.shell_quote(address <> ":8123")} " <>
        "--host #{Runtime.shell_quote(host)} --tls --health-check-path /ping"

    Runtime.execute(run, command, "HTTPS route registration")
  end
end
