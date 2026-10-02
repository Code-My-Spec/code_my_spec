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
end
