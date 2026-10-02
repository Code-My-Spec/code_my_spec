defmodule CodeMySpec.ClickHouseCassetteHelpers do
  @moduledoc """
  Cassette wiring for `Observability.ClickHouseClient`.

  Recorded against a real, throwaway ClickHouse container seeded with the
  exact DDL the OpenTelemetry Collector's ClickHouse exporter creates
  (`otel_logs`/`otel_traces`) — not against the live UAT box, and not
  against production credentials, since story 1081 (provisioning) has not
  shipped a per-project user for any project yet. What these cassettes
  prove is "this client builds a request ClickHouse accepts and parses the
  response correctly", not "this project's row policy is configured
  right" — that half is 1081's to prove.

  ## Re-recording

      docker run -d --rm --name cms-obs-test-ch -p 18123:8123 \\
        -e CLICKHOUSE_USER=tel_test_uat -e CLICKHOUSE_PASSWORD=test-password-123 \\
        -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 clickhouse/clickhouse-server:24.8

      # create otel_logs/otel_traces with the upstream exporter's DDL, seed
      # rows, then:
      CLICKHOUSE_RECORD=1 CLICKHOUSE_TEST_URL=http://localhost:18123 \\
        CLICKHOUSE_TEST_USER=tel_test_uat CLICKHOUSE_TEST_PASSWORD=test-password-123 \\
        mix test test/code_my_spec/observability/click_house_client_test.exs
  """

  alias CodeMySpec.ProjectSecrets
  alias Plug.Conn

  @cassette_dir "test/cassettes/click_house"

  def cassette_opts(extra \\ []) do
    Keyword.merge(
      [
        cassette_dir: @cassette_dir,
        mode: mode(),
        match_requests_on: [:method, :uri, :body],
        filter_request_headers: ["x-clickhouse-key"],
        filter_response_headers: ["set-cookie"]
      ],
      extra
    )
  end

  def with_plug(plug, fun) do
    module = CodeMySpec.Observability.ClickHouseClient
    original = Application.get_env(:code_my_spec, module, [])
    Application.put_env(:code_my_spec, module, Keyword.put(original, :plug, plug))

    try do
      fun.()
    after
      Application.put_env(:code_my_spec, module, original)
    end
  end

  @doc "The throwaway test container's connection, real while recording."
  def conn do
    if record?() do
      %{
        url: System.fetch_env!("CLICKHOUSE_TEST_URL"),
        username: System.fetch_env!("CLICKHOUSE_TEST_USER"),
        password: System.fetch_env!("CLICKHOUSE_TEST_PASSWORD")
      }
    else
      %{url: "http://localhost:18123", username: "tel_test_uat", password: "replay-password"}
    end
  end

  def record?, do: System.get_env("CLICKHOUSE_RECORD") in ~w(1 true yes)

  defp mode, do: if(record?(), do: :record, else: :replay)

  @doc """
  Which canned result a stub should answer with, keyed by which table the
  request's SQL body names — for a stub standing in for two different
  queries (a trace's spans and its logs; log errors and span errors) behind
  one `Req.Test.stub/2` call. Not a test file, so an ordinary `if` is fine
  here.
  """
  def pick_for_table(body, traces_result, logs_result) do
    if String.contains?(body, "FROM otel_traces"), do: traces_result, else: logs_result
  end

  @doc """
  Writes a project's ClickHouse connection into `ProjectSecrets` for one
  environment — the same mechanism story 1081 (provisioning) will use,
  not a shortcut around it. Returns the connection map for convenience
  (e.g. to assert a stub only ever sees this exact username).
  """
  def configure!(scope, opts \\ []) do
    env = Keyword.get(opts, :environment, "uat")
    conn = %{
      url: Keyword.get(opts, :url, "http://ch-#{scope.active_project_id}.test"),
      username: Keyword.get(opts, :username, "tel_#{scope.active_project_id}_#{env}"),
      password: Keyword.get(opts, :password, "secret")
    }

    {:ok, _} = ProjectSecrets.put_value(scope, "CLICKHOUSE_URL", conn.url, environment: env)

    {:ok, _} =
      ProjectSecrets.put_value(scope, "CLICKHOUSE_USERNAME", conn.username, environment: env)

    {:ok, _} =
      ProjectSecrets.put_value(scope, "CLICKHOUSE_PASSWORD", conn.password, environment: env)

    conn
  end

  @doc "Stubs a flat JSON-lines response — every call gets the same rows."
  def stub_rows(rows) do
    body = Enum.map_join(rows, "\n", &Jason.encode!/1)
    Req.Test.stub(CodeMySpec.Observability.ClickHouseClient, fn conn -> Conn.send_resp(conn, 200, body) end)
  end

  @doc """
  Stubs a response that only ever answers requests authenticated as
  `expected_username` — anything else fails the test loudly, from inside
  the stub, rather than silently returning the wrong project's data. This
  is the client-side half of rule `094d4f4b` ("nothing it passes can
  widen that"): the only thing that can change which rows come back is
  which credentials the scope resolved to, never a tool argument.
  """
  def stub_rows_for_username(expected_username, rows) do
    stub_rows_by_username(%{expected_username => rows})
  end

  @doc """
  Like `stub_rows_for_username/2`, but for a stub that has to tell two
  (or more) projects' connections apart and answer each with its own
  canned rows — a username not in `rows_by_username` fails the test
  loudly, from inside the stub, rather than silently answering with
  someone else's data. This is the client-side half of rule `094d4f4b`
  ("nothing it passes can widen that").
  """
  def stub_rows_by_username(rows_by_username) do
    Req.Test.stub(CodeMySpec.Observability.ClickHouseClient, fn conn ->
      body_for_username(rows_by_username, auth_username(conn))
      |> then(&Conn.send_resp(conn, 200, &1))
    end)
  end

  defp body_for_username(rows_by_username, username) do
    case Map.fetch(rows_by_username, username) do
      {:ok, rows} -> Enum.map_join(rows, "\n", &Jason.encode!/1)
      :error -> raise "unexpected ClickHouse auth #{inspect(username)} — " <>
                  "a query reached a connection no project configured for this stub"
    end
  end

  defp auth_username(conn) do
    case Conn.get_req_header(conn, "x-clickhouse-user") do
      [username] -> username
      other -> raise "expected exactly one X-ClickHouse-User header, got #{inspect(other)}"
    end
  end

  @doc """
  Stubs ClickHouseClient, recording the request's SQL body and query
  params where a spex's `then_` can read them back via
  `captured_request/1` — a side channel that keeps the spex file itself
  free of a raw `send`/`case`, neither of which `_spex.exs` files may use
  directly.
  """
  def stub_and_capture(expected_username, response_body \\ "") do
    {:ok, agent} = Agent.start_link(fn -> nil end)

    Req.Test.stub(CodeMySpec.Observability.ClickHouseClient, fn conn ->
      {:ok, body, conn} = Conn.read_body(conn)
      conn = Conn.fetch_query_params(conn)
      ^expected_username = auth_username(conn)
      Agent.update(agent, fn _ -> {body, conn.params} end)
      Conn.send_resp(conn, 200, response_body)
    end)

    agent
  end

  @doc "The `{body, params}` the last request `stub_and_capture/2` saw."
  def captured_request(agent), do: Agent.get(agent, & &1)
end
