defmodule CodeMySpec.Provisioning.ClickHouse.Stack do
  @moduledoc false

  alias CodeMySpec.Provisioning.ClickHouse.{Config, Runtime, Schema}

  @clickhouse "clickhouse/clickhouse-server:26.8"
  @collector "clickhouse/clickstack-otel-collector:2.40.0"
  @vector "timberio/vector:0.58.0-debian"
  @admin_file "/etc/cms-clickhouse/secrets.env"
  @writer_file "/etc/cms-otel-collector/secrets.env"

  def install(run, credentials, services) do
    with :ok <- network(run),
         :ok <- configuration(run, credentials),
         :ok <- clickhouse(run, credentials.admin),
         :ok <- await_database(run),
         :ok <- Schema.migrate(run, @admin_file),
         :ok <-
           Schema.authorize(
             run,
             credentials.writer,
             credentials.owner,
             credentials.reader,
             services
           ),
         :ok <- queue_storage(run),
         :ok <- collector(run, credentials.writer),
         :ok <- await_collector(run),
         :ok <- vector(run) do
      :ok
    end
  end

  defp network(run) do
    Runtime.execute(
      run,
      "docker network inspect db_net >/dev/null 2>&1 || docker network create db_net >/dev/null",
      "private network setup"
    )
  end

  defp configuration(run, credentials) do
    files = [
      {@admin_file, env(credentials.admin) <> "CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1\n", "600"},
      {@writer_file, env(credentials.writer), "600"},
      {"/etc/cms-clickhouse/low-memory.xml", Config.server(), "644"},
      {"/etc/cms-clickhouse/zz-networks.xml", Config.users(), "644"},
      {"/etc/cms-otel-collector/config.yaml", Config.collector(), "644"},
      {"/etc/cms-vector/vector.yaml", Config.vector(), "644"}
    ]

    Enum.reduce_while(files, :ok, fn {path, body, mode}, :ok ->
      case Runtime.write_file(run, path, body, mode) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp clickhouse(run, admin) do
    arguments =
      "--network db_net --memory 1280m --ulimit nofile=262144:262144 " <>
        "--env-file #{@admin_file} " <>
        "-v cms-clickhouse-data:/var/lib/clickhouse " <>
        "-v /etc/cms-clickhouse/low-memory.xml:/etc/clickhouse-server/config.d/low-memory.xml:ro " <>
        "-v /etc/cms-clickhouse/zz-networks.xml:/etc/clickhouse-server/users.d/zz-networks.xml:ro"

    Runtime.ensure_container(run, "cms-clickhouse", @clickhouse, arguments, [
      Config.server(),
      Config.users(),
      admin
    ])
  end

  defp await_database(run) do
    command = """
    set -eu
    attempt=0
    until docker exec cms-clickhouse wget -q -O- http://127.0.0.1:8123/ping >/dev/null 2>&1; do
      attempt=$((attempt + 1))
      if [ "$attempt" -ge 30 ]; then exit 1; fi
      sleep 1
    done
    """

    Runtime.execute(run, command, "database readiness")
  end

  defp queue_storage(run) do
    command =
      "docker run --rm --network none --user 0 " <>
        "-v cms-otel-collector-data:/var/lib/otelcol --entrypoint /bin/sh #{@collector} " <>
        Runtime.shell_quote("-c") <>
        " " <>
        Runtime.shell_quote(
          "mkdir -p /var/lib/otelcol/queue && chown -R 10001:10001 /var/lib/otelcol"
        )

    Runtime.execute(run, command, "persistent queue preparation")
  end

  defp collector(run, writer) do
    arguments =
      "--network db_net --memory 384m --env-file #{@writer_file} " <>
        "-v cms-otel-collector-data:/var/lib/otelcol " <>
        "-v /etc/cms-otel-collector/config.yaml:/etc/otelcol/config.yaml:ro " <>
        "--entrypoint /otelcontribcol"

    Runtime.ensure_container(
      run,
      "cms-otel-collector",
      @collector,
      arguments,
      [Config.collector(), writer],
      ["--config", "/etc/otelcol/config.yaml"]
    )
  end

  defp await_collector(run) do
    command = """
    set -eu
    attempt=0
    until docker exec cms-clickhouse wget -q -O- http://cms-otel-collector:13133/ >/dev/null 2>&1; do
      attempt=$((attempt + 1))
      if [ "$attempt" -ge 30 ]; then exit 1; fi
      sleep 1
    done
    """

    Runtime.execute(run, command, "collector readiness")
  end

  defp vector(run) do
    arguments =
      "--network db_net --memory 256m --user 0 " <>
        "-v cms-vector-data:/var/lib/vector " <>
        "-v /var/run/docker.sock:/var/run/docker.sock:ro " <>
        "-v /etc/cms-vector/vector.yaml:/etc/vector/vector.yaml:ro"

    Runtime.ensure_container(run, "cms-vector", @vector, arguments, Config.vector(), [
      "--config",
      "/etc/vector/vector.yaml"
    ])
  end

  defp env(%{username: username, password: password}) do
    if Enum.any?([username, password], &String.contains?(&1, ["\n", "\r", <<0>>])) do
      raise ArgumentError, "invalid telemetry credential encoding"
    end

    "CLICKHOUSE_USER=#{username}\nCLICKHOUSE_PASSWORD=#{password}\n"
  end
end
