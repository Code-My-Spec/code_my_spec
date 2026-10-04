defmodule CodeMySpec.Telemetry.ReaderTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpecSpex.ClickHouseCassetteHelpers, only: [configure!: 2]

  alias CodeMySpec.Observability.ClickHouseClient
  alias CodeMySpec.Telemetry

  setup do
    scope = full_scope_fixture()
    configure!(scope, environment: "prod", username: "project_prod_reader")
    %{scope: scope}
  end

  test "default query uses the requested environment credentials for both signals", %{
    scope: scope
  } do
    Req.Test.expect(ClickHouseClient, 2, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-clickhouse-user") == ["project_prod_reader"]
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.params["param_limit"] == "101"
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:ok, %{logs: [], traces: [], truncated: false}} = Telemetry.query(scope, "prod")
  end

  test "default check reports an explicit write denial", %{scope: scope} do
    Req.Test.expect(ClickHouseClient, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)

    Req.Test.expect(ClickHouseClient, fn conn ->
      {:ok, sql, conn} = Plug.Conn.read_body(conn)
      assert sql == "INSERT INTO otel_logs (Timestamp, Body) SELECT now64(9), '' WHERE 0"
      Plug.Conn.send_resp(conn, 403, "Code: 497. ACCESS_DENIED")
    end)

    assert %{reachable: true, reads: :ok, writes: :refused, checked_at: %DateTime{}} =
             Telemetry.check(scope, "prod")
  end

  test "a failed write request is not evidence of read-only permissions", %{scope: scope} do
    Req.Test.expect(ClickHouseClient, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)

    Req.Test.expect(ClickHouseClient, fn conn -> Plug.Conn.send_resp(conn, 502, "Bad Gateway") end)

    assert %{reachable: true, reads: :ok, writes: :error} = Telemetry.check(scope, "prod")
  end

  test "a writable credential is reported as writable", %{scope: scope} do
    Req.Test.expect(ClickHouseClient, 2, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)

    assert %{reachable: true, reads: :ok, writes: :ok} = Telemetry.check(scope, "prod")
  end

  test "an unconfigured environment does not use another environment's credentials", %{
    scope: scope
  } do
    assert {:error, :not_configured} = Telemetry.query(scope, "uat")
    assert %{reachable: false, reads: :error, writes: :error} = Telemetry.check(scope, "uat")
  end

  test "invalid retention windows are rejected", %{scope: scope} do
    assert {:error, "since_days must be an integer between 1 and 14"} =
             Telemetry.query(scope, "prod", since_days: 15)
  end
end
