defmodule CodeMySpec.Provisioning.ClickHouse.Schema do
  @moduledoc false

  alias CodeMySpec.Provisioning.ClickHouse.{Permissions, Runtime}

  @collector_image "clickhouse/clickstack-otel-collector:2.40.0"

  def migrate(run, admin_env_file) do
    command =
      "docker run --rm --network container:cms-clickhouse " <>
        "--env-file #{Runtime.shell_quote(admin_env_file)} " <>
        "-e CLICKHOUSE_ENDPOINT=tcp://127.0.0.1:9000 " <>
        "-e HYPERDX_OTEL_EXPORTER_CLICKHOUSE_DATABASE=otel " <>
        "-e HYPERDX_OTEL_EXPORTER_TABLES_TTL=336h " <>
        "-e HYPERDX_OTEL_EXPORTER_RECONCILE_TABLE_TTL=true " <>
        "--entrypoint /usr/local/bin/migrate #{@collector_image} /etc/otel/schema/seed"

    Runtime.execute(run, command, "schema migration")
  end

  def authorize(run, writer, owner, reader, services) do
    with {:ok, tables} <- tables(run),
         true <- Enum.all?(~w(otel_logs otel_traces), &(&1 in tables)) do
      sql =
        Permissions.rollup_sql() <>
          Permissions.writer_sql(writer.username, writer.password) <>
          Permissions.owner_sql(owner.username, owner.password, tables) <>
          Permissions.reader_sql(reader.username, reader.password, services, tables)

      execute_sql(run, sql)
    else
      false -> {:error, "telemetry migration did not create the required signal tables"}
      {:error, _} = error -> error
    end
  end

  def restrict_writer(run) do
    command =
      "docker network inspect --format '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' db_net"

    with {:ok, output} <- Runtime.capture(run, command, "ingest network discovery") do
      subnets = String.split(output, "\n", trim: true)

      if subnets != [] and
           Enum.all?(subnets, &Regex.match?(~r/\A[0-9a-fA-F:.]+\/[0-9]{1,3}\z/, &1)) do
        hosts = Enum.map_join(subnets, ", ", &("'" <> &1 <> "'"))
        execute_sql(run, "ALTER USER cms_writer HOST IP #{hosts};")
      else
        {:error, "could not determine the telemetry ingest subnet"}
      end
    end
  end

  defp tables(run) do
    sql =
      "SELECT name FROM system.tables WHERE database = 'otel' AND startsWith(name, 'otel_') ORDER BY name FORMAT TabSeparated"

    with {:ok, output} <- Runtime.capture(run, sql_command(sql), "table discovery") do
      names = String.split(output, "\n", trim: true)

      if Enum.all?(names, &Regex.match?(~r/\Aotel_[a-zA-Z0-9_]+\z/, &1)) do
        {:ok, names}
      else
        {:error, "telemetry table discovery returned an unexpected identifier"}
      end
    end
  end

  defp execute_sql(run, sql) do
    Runtime.execute(run, sql_command(sql), "access policy reconciliation")
  end

  defp sql_command(sql) do
    # The administrator is used inside its container. Do not return SQL or
    # ClickHouse error output: user creation statements contain passwords.
    client =
      ~S(exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --multiquery)

    "printf %s #{Runtime.shell_quote(sql)} | " <>
      "docker exec -i cms-clickhouse sh -c #{Runtime.shell_quote(client)}"
  end
end
