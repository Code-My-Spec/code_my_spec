defmodule CodeMySpecLocalWeb.AnalysisController do
  @moduledoc """
  Model-facing analysis runs — the endpoint the PreToolUse hook rewrites
  `mix test` / `mix spex` into.

  Runs the analyzer through the same single-flight `Analysis` service the
  stop hook uses: one shared run record, Problems reconciled centrally, and
  a duplicate concurrent request joins the in-flight execution instead of
  double-running. The response body is the raw tool output and nothing
  else — pass/fail travels as the HTTP status (200 clean, 422 otherwise)
  rather than a line appended to the body, because the rewritten curl script
  reads that without the agent ever seeing it. A `mix test` routed through
  here has to come back looking exactly like one that was not.

  Blocks for as long as the run takes; Bandit doesn't time out long-running
  handlers, and the rewritten Bash command carries a raised tool timeout.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.Analysis
  alias CodeMySpec.Problems

  @valid_sources ~w(compiler credo exunit spex)

  # Long enough that reaching it means something is broken rather than slow.
  # A sweep is 200-590s; this is twenty minutes.
  @wait_timeout :timer.minutes(20)

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

  @doc """
  Block until this project's background analysis is idle, then report it.

  The stop hook enqueues analyzers and decides from persisted problems, so an
  agent that wants to stop against fresh results has to wait for them. This is
  where that waiting happens.

  It is an HTTP endpoint rather than an MCP tool on purpose. The same wait
  existed as `await_analysis` and could not work: MCP's streamable-HTTP
  transport caps a request at 30s (`@default_timeout 30_000`), sweeps here run
  200-590s, and the transport's `GenServer.call` died first — so the tool
  answered `-32603 Server unavailable` every time it was needed, which reads as
  an outage rather than a timeout. Bounding the wait to fit under the cap
  worked but cost 10 calls and ~200s to wait out one queued spex run.

  Nothing caps this one. Bandit does not time out long-running handlers, which
  is the same property the `run` endpoint above already depends on. The agent
  fires it in the background and is notified when it returns, so one call covers
  a wait of any length.
  """
  def wait(conn, _params) do
    scope = conn.assigns.current_scope

    if is_nil(scope.active_project_id) do
      conn
      |> put_status(422)
      |> text("no project linked for this working directory — nothing to wait for")
    else
      Logger.info("[AnalysisAPI] waiting for analysis to finish")
      text(conn, wait_body(scope, Analysis.await_all(scope, timeout: @wait_timeout)))
    end
  end

  # `:timeout` and `:ok` are different answers and are reported as different
  # answers. Returning "analysis complete" after giving up is the failure this
  # whole endpoint exists to replace.
  defp wait_body(scope, :ok), do: "Analysis complete.\n\n" <> summary(scope)

  defp wait_body(scope, :timeout) do
    """
    Still running after #{div(@wait_timeout, 60_000)} minutes — not finished.

    #{summary(scope)}
    Something is wrong: a sweep on this project runs 200-590s. Check the
    harness log before waiting again.
    """
  end

  defp summary(scope) do
    counts =
      scope
      |> Problems.list_project_problems([])
      |> Enum.group_by(& &1.source)
      |> Map.new(fn {source, problems} -> {source, length(problems)} end)

    scope
    |> Analysis.status()
    |> Enum.map_join("\n", fn {source, %{state: state}} ->
      "- #{source}: #{state}, #{Map.get(counts, source, 0)} problem(s)"
    end)
    |> Kernel.<>("\n")
  end

  defp execute(conn, scope, source, args) do
    Logger.info("[AnalysisAPI] #{source} #{Enum.join(args, " ")}")

    requested_by = %{kind: "agent_mix_test", via: "local_http"}

    case Analysis.await_run(scope, source, args, requested_by: requested_by) do
      {:ok, run} ->
        status = run.exit_status || exit_for(run)

        conn
        |> put_status(if status == 0, do: 200, else: 422)
        |> text(run.output || "")

      {:error, reason} ->
        conn
        |> put_status(500)
        |> text("analysis run failed: #{inspect(reason)}")
    end
  end

  # A run that failed without a recorded tool exit (crash, skip, timeout)
  # still needs a non-zero marker.
  defp exit_for(%{status: :completed}), do: 0
  defp exit_for(_run), do: 1

  defp tool_name("spex"), do: "spex"
  defp tool_name(_source), do: "test"
end
