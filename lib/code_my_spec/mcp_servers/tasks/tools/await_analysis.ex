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

  # Under the ProjectServer's 30-minute per-job ceiling, but generous enough
  # for a compile + full-suite + spex queue on a large project.
  @await_timeout :timer.minutes(20)

  schema do
  end

  @impl true
  def execute(_params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      Analysis.await_all(scope, timeout: @await_timeout)
      {:reply, Response.tool() |> Response.text(summary(scope)), frame}
    else
      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("#{inspect(reason)}"), frame}
    end
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
