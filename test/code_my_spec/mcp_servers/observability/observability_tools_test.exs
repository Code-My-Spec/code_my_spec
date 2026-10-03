defmodule CodeMySpec.McpServers.Observability.ObservabilityToolsTest do
  @moduledoc """
  The MCP wiring for story 1116 ("1082"): frame → scope → `Observability` →
  a text reply an agent can read. `ObservabilityTest` already covers the
  context module's own logic (defaults, truncation, param binding); this
  covers each tool actually reaching it and shaping the reply.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Observability.Tools.{ErrorSummary, GetTrace, QueryLogs, SlowSpans}
  alias CodeMySpec.Observability.ClickHouseClient
  alias CodeMySpec.ProjectSecrets

  setup do
    scope = full_scope_fixture()
    %{scope: scope, frame: %Frame{assigns: %{current_scope: scope}}}
  end

  defp configure!(scope, env \\ "uat") do
    {:ok, _} = ProjectSecrets.put_value(scope, "CLICKHOUSE_URL", "http://ch.test", environment: env)
    {:ok, _} = ProjectSecrets.put_value(scope, "CLICKHOUSE_USERNAME", "u", environment: env)
    {:ok, _} = ProjectSecrets.put_value(scope, "CLICKHOUSE_PASSWORD", "p", environment: env)
  end

  defp stub_rows(rows) do
    body = Enum.map_join(rows, "\n", &Jason.encode!/1)
    Req.Test.stub(ClickHouseClient, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)
  end

  defp text(response), do: Enum.map_join(response.content, "\n", &Map.get(&1, "text", ""))

  describe "query_logs" do
    test "an unconfigured project is told to provision telemetry, not given a stack trace", ctx do
      {:reply, response, _frame} = QueryLogs.execute(%{}, ctx.frame)

      assert response.isError
      assert text(response) =~ "provisioning step"
    end

    test "a matching project renders its rows", ctx do
      configure!(ctx.scope)
      stub_rows([%{"Timestamp" => "t", "SeverityText" => "ERROR", "Body" => "boom", "TraceId" => "abc"}])

      {:reply, response, _frame} = QueryLogs.execute(%{}, ctx.frame)

      refute response.isError
      assert text(response) =~ "boom"
      assert text(response) =~ "trace abc"
    end

    test "an unparseable timestamp is refused with a clear reason", ctx do
      {:reply, response, _frame} = QueryLogs.execute(%{since: "not-a-date"}, ctx.frame)

      assert response.isError
      assert text(response) =~ "not-a-date"
    end
  end

  describe "get_trace" do
    test "a trace nothing emitted is reported not found, not as an empty success", ctx do
      configure!(ctx.scope)
      stub_rows([])

      {:reply, response, _frame} = GetTrace.execute(%{trace_id: "ghost"}, ctx.frame)

      assert response.isError
      assert text(response) =~ "ghost"
    end
  end

  describe "slow_spans" do
    test "renders the slowest span with its duration in ms", ctx do
      configure!(ctx.scope)

      stub_rows([
        %{
          "Timestamp" => "t",
          "SpanName" => "Repo.query",
          "Duration" => "1850000000",
          "TraceId" => "abc",
          "StatusCode" => "Error"
        }
      ])

      {:reply, response, _frame} = SlowSpans.execute(%{}, ctx.frame)

      refute response.isError
      assert text(response) =~ "1850ms"
    end
  end

  describe "error_summary" do
    test "an unconfigured project is told to provision telemetry", ctx do
      {:reply, response, _frame} = ErrorSummary.execute(%{}, ctx.frame)

      assert response.isError
      assert text(response) =~ "provisioning step"
    end
  end
end
