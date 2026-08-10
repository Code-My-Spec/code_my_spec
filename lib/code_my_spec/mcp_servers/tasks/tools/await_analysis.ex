defmodule CodeMySpec.McpServers.Tasks.Tools.AwaitAnalysis do
  @moduledoc """
  Block until the project's in-flight background analysis finishes, then
  return a compact per-source summary.

  The stop hook enqueues analyzers (compile, credo, tests, spex) as
  background runs and decides from persisted problems — when it blocks with
  "analysis is still running", this tool is the wait affordance: the agent's
  turn is legally consumed waiting, and the next stop evaluates against
  fresh results.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Analysis
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Problems

  # One wait has to finish inside the MCP transport's request timeout, which is
  # 30s (`Anubis.Server.Transport.StreamableHTTP.Plug`, `@default_timeout
  # 30_000`). This waited 20 minutes, so the transport's `GenServer.call` gave
  # up first and the tool answered `-32603 Server unavailable` — every single
  # time it was needed. Sweeps here run 200-590s, so the only case it could ever
  # have served was an analysis that was already about to finish.
  #
  # The failure was worse than a plain timeout: "Server unavailable" describes a
  # server that is down, and :4000 was serving other requests throughout. The
  # one escape hatch from waiting on the analyzer looked like an outage.
  #
  # So a call now waits a bounded slice and says which it is — finished, or
  # still running and call again. The agent's turn is still legally consumed
  # waiting, which is the point of the tool; it just takes several calls on a
  # long queue instead of one that cannot return.
  @slice :timer.seconds(20)

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        text =
          case Analysis.await_all(scope, timeout: @slice) do
            :ok -> summary(scope)
            :timeout -> still_running(scope)
          end

        {:reply, Response.tool() |> Response.text(text), frame}

      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("#{inspect(reason)}"), frame}
    end
  end

  defp still_running(scope) do
    sources = Analysis.in_flight(scope)

    """
    Still running after #{div(@slice, 1000)}s: #{Enum.join(sources, ", ")}.

    Call `await_analysis` again to keep waiting. A full sweep on this project
    runs 200-590s, so several calls is normal and does not mean anything is
    stuck.
    """
  end

  defp summary(scope) do
    status = Analysis.status(scope)

    problem_counts =
      scope
      |> Problems.list_project_problems([])
      |> Enum.group_by(& &1.source)
      |> Map.new(fn {source, problems} -> {source, length(problems)} end)

    lines =
      Enum.map_join(status, "\n", fn {source, %{state: state}} ->
        count = Map.get(problem_counts, source, 0)
        "- #{source}: #{state}, #{count} problem(s)"
      end)

    total = problem_counts |> Map.values() |> Enum.sum()

    footer =
      if total > 0 do
        "\n\nProblems are persisted — stop again to get the blocking detail, or fix and re-run."
      else
        "\n\nAll clean."
      end

    "Analysis complete.\n\n#{lines}#{footer}"
  end
end
