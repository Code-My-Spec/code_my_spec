defmodule CodeMySpecLocalWeb.AnalysisController do
  @moduledoc """
  Model-facing analysis runs — the endpoint the PreToolUse hook rewrites
  `mix test` / `mix spex` into.

  Runs the analyzer through the same single-flight `Analysis` service the
  stop hook uses: one shared run record, Problems reconciled centrally, and
  a duplicate concurrent request joins the in-flight execution instead of
  double-running. The response body is the raw tool output (so the agent
  reads normal test results) plus a trailing exit-status marker line — curl
  exits 0 even when tests fail, so the marker is how the agent (and any
  wrapper) distinguishes pass from fail.

  Blocks for as long as the run takes; Bandit doesn't time out long-running
  handlers, and the rewritten Bash command carries a raised tool timeout.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.Analysis

  @valid_sources ~w(compiler credo exunit spex)

  def run(conn, params) do
    scope = conn.assigns.current_scope
    source = Map.get(params, "source")
    args = Map.get(params, "args", [])

    cond do
      source not in @valid_sources ->
        conn
        |> put_status(422)
        |> text("unknown analyzer source: #{inspect(source)} (expected one of #{Enum.join(@valid_sources, ", ")})")

      is_nil(scope.active_project_id) or is_nil(scope.cwd) ->
        conn
        |> put_status(422)
        |> text("no project linked for this working directory — run mix #{tool_name(source)} directly")

      not is_list(args) or not Enum.all?(args, &is_binary/1) ->
        conn
        |> put_status(422)
        |> text("args must be a list of strings")

      true ->
        execute(conn, scope, source, args)
    end
  end

  defp execute(conn, scope, source, args) do
    Logger.info("[AnalysisAPI] #{source} #{Enum.join(args, " ")}")

    case Analysis.await_run(scope, source, args) do
      {:ok, run} ->
        body = """
        #{run.output || ""}

        ── analysis run #{run.id}: #{run.status}, #{stats_line(run)} ──
        exit status: #{run.exit_status || exit_for(run)}
        """

        text(conn, body)

      {:error, reason} ->
        conn
        |> put_status(500)
        |> text("analysis run failed: #{inspect(reason)}")
    end
  end

  defp stats_line(%{stats: stats}) when is_map(stats) and map_size(stats) > 0 do
    Enum.map_join(stats, ", ", fn {k, v} -> "#{k}: #{v}" end)
  end

  defp stats_line(_run), do: "no stats"

  # A run that failed without a recorded tool exit (crash, skip, timeout)
  # still needs a non-zero marker.
  defp exit_for(%{status: :completed}), do: 0
  defp exit_for(_run), do: 1

  defp tool_name("spex"), do: "spex"
  defp tool_name(_source), do: "test"
end
