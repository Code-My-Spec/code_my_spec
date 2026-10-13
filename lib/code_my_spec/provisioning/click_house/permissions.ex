defmodule CodeMySpec.Provisioning.ClickHouse.Permissions do
  @moduledoc false

  @readable_tables ~w(otel_logs otel_traces)

  # The caller discovers every otel_* table after running the pinned seeds.
  # Rollups have lost service identity, so their policy denies all rows and
  # the reader receives no SELECT grant on them.
  def reader_sql(username, password, services, tables) when services != [] do
    user = identifier(username)
    profile = identifier(username <> "_limits")
    quota = identifier(username <> "_quota")
    service_list = if services == :all, do: nil, else: Enum.map_join(services, ", ", &literal/1)

    policies =
      Enum.map_join(tables, "\n", fn table ->
        table_id = identifier(table)
        policy = identifier(username <> "_scope")

        condition =
          cond do
            services == :all -> "1"
            table in @readable_tables -> "ServiceName IN (#{service_list})"
            true -> "0"
          end

        "CREATE ROW POLICY IF NOT EXISTS #{policy} ON otel.#{table_id} FOR SELECT USING #{condition} TO #{user};\n" <>
          "ALTER ROW POLICY #{policy} ON otel.#{table_id} FOR SELECT USING #{condition} TO #{user};"
      end)

    """
    CREATE USER IF NOT EXISTS #{user} IDENTIFIED WITH sha256_password BY #{literal(password)};
    ALTER USER #{user} IDENTIFIED WITH sha256_password BY #{literal(password)} DEFAULT DATABASE otel;
    REVOKE ALL ON *.* FROM #{user};
    CREATE SETTINGS PROFILE IF NOT EXISTS #{profile};
    ALTER SETTINGS PROFILE #{profile} SETTINGS
      readonly = 1 CONST,
      max_execution_time = 30 CONST,
      max_memory_usage = 268435456 CONST,
      max_rows_to_read = 10000000 CONST,
      max_result_rows = 10000 CONST,
      max_result_bytes = 16777216 CONST,
      result_overflow_mode = 'throw' CONST
    TO #{user};
    CREATE QUOTA IF NOT EXISTS #{quota};
    ALTER QUOTA #{quota} FOR INTERVAL 1 HOUR MAX queries = 1000 TO #{user};
    #{policies}
    GRANT SELECT ON otel.otel_logs TO #{user};
    GRANT SELECT ON otel.otel_traces TO #{user};
    """
  end

  def owner_sql(username, password, tables) do
    reader_sql(username, password, :all, tables) <>
      "GRANT SELECT ON otel.* TO #{identifier(username)};\n"
  end

  def writer_sql(username, password) do
    user = identifier(username)

    """
    CREATE USER IF NOT EXISTS #{user} IDENTIFIED WITH sha256_password BY #{literal(password)};
    ALTER USER #{user} IDENTIFIED WITH sha256_password BY #{literal(password)} DEFAULT DATABASE otel;
    REVOKE ALL ON *.* FROM #{user};
    GRANT INSERT ON otel.otel_logs TO #{user};
    GRANT INSERT ON otel.otel_traces TO #{user};
    """
  end

  def rollup_sql do
    """
    CREATE USER IF NOT EXISTS cms_rollup HOST NONE;
    ALTER USER cms_rollup HOST NONE;
    REVOKE ALL ON *.* FROM cms_rollup;
    GRANT SELECT ON otel.otel_logs TO cms_rollup;
    GRANT SELECT ON otel.otel_traces TO cms_rollup;
    GRANT INSERT ON otel.otel_logs_kv_rollup_15m TO cms_rollup;
    GRANT INSERT ON otel.otel_traces_kv_rollup_15m TO cms_rollup;
    CREATE ROW POLICY IF NOT EXISTS cms_rollup_all ON otel.otel_logs FOR SELECT USING 1 TO cms_rollup;
    ALTER ROW POLICY cms_rollup_all ON otel.otel_logs FOR SELECT USING 1 TO cms_rollup;
    CREATE ROW POLICY IF NOT EXISTS cms_rollup_all ON otel.otel_traces FOR SELECT USING 1 TO cms_rollup;
    ALTER ROW POLICY cms_rollup_all ON otel.otel_traces FOR SELECT USING 1 TO cms_rollup;
    ALTER TABLE otel.otel_logs_attr_kv_rollup_15m_mv MODIFY SQL SECURITY DEFINER DEFINER = cms_rollup;
    ALTER TABLE otel.otel_traces_kv_rollup_15m_mv MODIFY SQL SECURITY DEFINER DEFINER = cms_rollup;
    """
  end

  defp identifier(value) do
    if Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_]*\z/, value),
      do: value,
      else: raise(ArgumentError, "invalid ClickHouse identifier")
  end

  defp literal(value) when is_binary(value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("'", "''")
    "'" <> escaped <> "'"
  end
end
