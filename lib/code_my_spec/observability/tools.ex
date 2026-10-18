defmodule CodeMySpec.Observability.Tools do
  @moduledoc "The telemetry tools an agent calls, and what they share."

  def all do
    [
      __MODULE__.QueryLogs,
      __MODULE__.GetTrace,
      __MODULE__.SlowSpans,
      __MODULE__.ErrorSummary
    ]
  end

  @doc "Runs `query` against the caller's project and renders what it finds."
  def run(context, query, format) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} -> answer(query.(scope), format)
      {:error, reason} -> {:error, "#{reason}"}
    end
  end

  defp answer({:ok, result}, format), do: {:ok, format.(result)}
  defp answer({:error, :not_configured}, _format), do: {:error, not_configured()}
  # A tool's own sentence; Observability itself never returns a string.
  defp answer({:error, reason}, _format) when is_binary(reason), do: {:error, reason}
  defp answer({:error, reason}, _format), do: {:error, inspect(reason)}

  defp not_configured do
    "This project has no telemetry set up for this environment yet. " <>
      "Run the telemetry provisioning step first."
  end

  @doc "Keyword options without the ones the caller left out."
  def opts(pairs), do: Enum.reject(pairs, fn {_k, v} -> is_nil(v) end)

  def parse_time(nil), do: {:ok, nil}

  def parse_time(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _reason} -> {:error, "could not parse timestamp #{inspect(iso8601)} as ISO 8601"}
    end
  end

  # ClickHouse's JSON output represents UInt64 (what `Duration` is, in
  # nanoseconds) as a string, to avoid precision loss past 2^53.
  def duration_ms(duration_ns), do: duration_ns |> String.to_integer() |> div(1_000_000)
end
