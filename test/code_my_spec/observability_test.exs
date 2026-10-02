defmodule CodeMySpec.ObservabilityTest do
  @moduledoc """
  Behavior against a stubbed ClickHouse — this layer's own claims (SQL
  shape, defaults, truncation, the not-configured path) rather than the
  wire protocol, which `ClickHouseClientTest` already proves against a
  real server. Story 1116 ("1082"), issue 577de9bb.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.ClickHouseCassetteHelpers
  alias CodeMySpec.Observability
  alias CodeMySpec.Observability.ClickHouseClient
  alias CodeMySpec.ProjectSecrets

  setup do
    scope = full_scope_fixture()

    {:ok, _} = ProjectSecrets.put_value(scope, "CLICKHOUSE_URL", "http://ch.test", environment: "uat")
    {:ok, _} = ProjectSecrets.put_value(scope, "CLICKHOUSE_USERNAME", "tel_test_uat", environment: "uat")
    {:ok, _} = ProjectSecrets.put_value(scope, "CLICKHOUSE_PASSWORD", "secret", environment: "uat")

    %{scope: scope}
  end

  defp stub_rows(rows) do
    body = Enum.map_join(rows, "\n", &Jason.encode!/1)
    Req.Test.stub(ClickHouseClient, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)
  end

  describe "query_logs/2" do
    test "a project with no telemetry configured is told so, not given an error", %{scope: _scope} do
      other_project_scope = full_scope_fixture()
      assert {:error, :not_configured} = Observability.query_logs(other_project_scope)
    end

    test "returns rows for the default (uat) environment and window", %{scope: scope} do
      stub_rows([%{"Timestamp" => "2026-01-01 00:00:00", "SeverityText" => "INFO", "Body" => "hi"}])

      assert {:ok, %{rows: [%{"Body" => "hi"}], truncated: false}} =
               Observability.query_logs(scope)
    end

    test "a result past the limit is reported truncated, trimmed to the limit", %{scope: scope} do
      stub_rows(for n <- 1..3, do: %{"Body" => "line #{n}"})

      assert {:ok, %{rows: rows, truncated: true}} = Observability.query_logs(scope, limit: 2)
      assert length(rows) == 2
    end

    test "an unconfigured environment is reported separately from uat", %{scope: scope} do
      assert {:error, :not_configured} = Observability.query_logs(scope, env: "prod")
    end
  end

  describe "get_trace/3" do
    test "joins spans and logs by trace id", %{scope: scope} do
      Req.Test.stub(ClickHouseClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        rows =
          ClickHouseCassetteHelpers.pick_for_table(
            body,
            [%{"SpanName" => "GET /app", "Duration" => "42000000", "StatusCode" => "Ok"}],
            [%{"Body" => "a log line"}]
          )

        Plug.Conn.send_resp(conn, 200, Enum.map_join(rows, "\n", &Jason.encode!/1))
      end)

      assert {:ok, %{spans: [%{"SpanName" => "GET /app"}], logs: [%{"Body" => "a log line"}]}} =
               Observability.get_trace(scope, "abc123")
    end

    test "a trace id nothing emitted is reported not found", %{scope: scope} do
      Req.Test.stub(ClickHouseClient, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)

      assert {:error, :not_found} = Observability.get_trace(scope, "no-such-trace")
    end
  end

  describe "slow_spans/2" do
    test "min_duration_ms is sent to ClickHouse in nanoseconds", %{scope: scope} do
      Req.Test.stub(ClickHouseClient, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.params["param_min_duration_ns"] == "500000000"
        Plug.Conn.send_resp(conn, 200, "")
      end)

      assert {:ok, %{rows: []}} = Observability.slow_spans(scope, min_duration_ms: 500)
    end
  end

  describe "error_summary/2" do
    test "combines log errors and failed spans", %{scope: scope} do
      Req.Test.stub(ClickHouseClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        row =
          ClickHouseCassetteHelpers.pick_for_table(
            body,
            %{"name" => "Repo.query", "message" => "boom", "count" => "1", "last_seen" => "x"},
            %{"message" => "oops", "count" => "3", "last_seen" => "x"}
          )

        Plug.Conn.send_resp(conn, 200, Jason.encode!(row))
      end)

      assert {:ok, %{log_errors: [%{"message" => "oops"}], span_errors: [%{"name" => "Repo.query"}]}} =
               Observability.error_summary(scope)
    end
  end
end
