defmodule CodeMySpec.Observability.ToolsTest do
  @moduledoc """
  The MCP wiring for story 1116 ("1082"): frame → scope → `Observability` →
  a text reply an agent can read. `ObservabilityTest` already covers the
  context module's own logic (defaults, truncation, param binding); this
  covers each tool actually reaching it and shaping the reply.
  """

  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Observability.ClickHouseClient
  alias CodeMySpec.ProjectSecrets

  setup do
    scope = full_scope_fixture()
    %{scope: scope, frame: %Frame{assigns: %{current_scope: scope}}}
  end

  defp configure!(scope, env \\ "uat") do
    {:ok, _} =
      ProjectSecrets.put_value(scope, "CLICKHOUSE_URL", "http://ch.test", environment: env)

    {:ok, _} = ProjectSecrets.put_value(scope, "CLICKHOUSE_USERNAME", "u", environment: env)
    {:ok, _} = ProjectSecrets.put_value(scope, "CLICKHOUSE_PASSWORD", "p", environment: env)
  end

  defp stub_rows(rows) do
    body = Enum.map_join(rows, "\n", &Jason.encode!/1)
    Req.Test.stub(ClickHouseClient, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)
  end

  defp text({_status, text}), do: text

  describe "query_logs" do
    test "an unconfigured project is told to provision telemetry, not given a stack trace", ctx do
      response =
        ToolLibrary.run(
          "query_logs",
          %{},
          Map.put(ctx.frame.assigns, :scope, ctx.frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
      assert text(response) =~ "provisioning step"
    end

    test "a matching project renders its rows", ctx do
      configure!(ctx.scope)

      stub_rows([
        %{"Timestamp" => "t", "SeverityText" => "ERROR", "Body" => "boom", "TraceId" => "abc"}
      ])

      response =
        ToolLibrary.run(
          "query_logs",
          %{},
          Map.put(ctx.frame.assigns, :scope, ctx.frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
      assert text(response) =~ "boom"
      assert text(response) =~ "trace abc"
    end

    test "an unparseable timestamp is refused with a clear reason", ctx do
      response =
        ToolLibrary.run("query_logs", %{since: "not-a-date"}, %{
          scope: ctx.frame.assigns.current_scope
        })

      assert match?({:error, _}, response)
      assert text(response) =~ "not-a-date"
    end
  end

  describe "get_trace" do
    test "a trace nothing emitted is reported not found, not as an empty success", ctx do
      configure!(ctx.scope)
      stub_rows([])

      response =
        ToolLibrary.run("get_trace", %{trace_id: "ghost"}, %{
          scope: ctx.frame.assigns.current_scope
        })

      assert match?({:error, _}, response)
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

      response =
        ToolLibrary.run(
          "slow_spans",
          %{},
          Map.put(ctx.frame.assigns, :scope, ctx.frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
      assert text(response) =~ "1850ms"
    end
  end

  describe "error_summary" do
    test "an unconfigured project is told to provision telemetry", ctx do
      response =
        ToolLibrary.run(
          "error_summary",
          %{},
          Map.put(ctx.frame.assigns, :scope, ctx.frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
      assert text(response) =~ "provisioning step"
    end
  end
end
