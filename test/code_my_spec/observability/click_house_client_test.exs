defmodule CodeMySpec.Observability.ClickHouseClientTest do
  @moduledoc """
  Recorded against a real ClickHouse container seeded with the OTel
  exporter's own DDL — see `ClickHouseCassetteHelpers` for why a stub
  would not do: the question here is whether the request this client
  builds (param binding, auth headers, `FORMAT JSONEachRow` parsing) is
  one ClickHouse actually accepts, which a `Req.Test` stub answers yes to
  unconditionally.
  """

  use ExUnit.Case, async: true

  import CodeMySpec.ClickHouseCassetteHelpers

  alias CodeMySpec.Observability.ClickHouseClient

  describe "query/3 against a real ClickHouse" do
    test "returns decoded rows for a matching query" do
      ReqCassette.with_cassette("logs_basic_match", cassette_opts(), fn plug ->
        with_plug(plug, fn ->
          sql = """
          SELECT Timestamp, SeverityText, Body, TraceId, SpanId
          FROM otel_logs
          WHERE Timestamp >= {since:DateTime64} AND Timestamp <= {until:DateTime64}
          ORDER BY Timestamp DESC
          LIMIT {limit:UInt32}
          """

          params = %{since: "2025-10-01 00:00:00", until: "2025-10-03 00:00:00", limit: 10}

          assert {:ok, rows} = ClickHouseClient.query(conn(), sql, params)
          assert length(rows) == 3
          assert %{"SeverityText" => "ERROR"} = hd(rows)
        end)
      end)
    end

    test "an empty result decodes to an empty list, not an error" do
      ReqCassette.with_cassette("logs_no_match", cassette_opts(), fn plug ->
        with_plug(plug, fn ->
          sql = """
          SELECT Timestamp, Body
          FROM otel_logs
          WHERE TraceId = {trace_id:String}
          """

          assert {:ok, []} = ClickHouseClient.query(conn(), sql, %{trace_id: "no-such-trace"})
        end)
      end)
    end

    test "a malformed query comes back as an error, not a raise" do
      ReqCassette.with_cassette("logs_bad_query", cassette_opts(), fn plug ->
        with_plug(plug, fn ->
          assert {:error, {:clickhouse_error, 404, _body}} =
                   ClickHouseClient.query(conn(), "SELECT * FROM no_such_table", %{})
        end)
      end)
    end

    test "groups and aggregates (the error_summary shape) decode correctly" do
      ReqCassette.with_cassette("logs_grouped", cassette_opts(), fn plug ->
        with_plug(plug, fn ->
          sql = """
          SELECT Body AS message, count() AS count, max(Timestamp) AS last_seen
          FROM otel_logs
          WHERE Timestamp >= {since:DateTime64} AND SeverityText IN ('ERROR', 'FATAL')
          GROUP BY Body
          ORDER BY count DESC
          LIMIT {limit:UInt32}
          """

          params = %{since: "2025-10-01 00:00:00", limit: 10}

          # ClickHouse's JSON output represents UInt64 (what `count()` returns)
          # as a string, to avoid precision loss for values past 2^53 — real
          # behavior worth pinning down here rather than assuming an integer.
          assert {:ok, [%{"message" => message, "count" => "2"}]} =
                   ClickHouseClient.query(conn(), sql, params)

          assert message =~ "column does not exist"
        end)
      end)
    end
  end
end
