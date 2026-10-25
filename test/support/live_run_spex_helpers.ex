defmodule CodeMySpecSpex.LiveRun do
  @moduledoc """
  Stories 1141 and 1144: Sam's suite, or credo, running for real on a live
  harness, so what he sees of it can be watched while it runs.

  The checkout is `CmsHarnessTest.ClusteredProject.make_suite/1`'s: a passing
  file, a failing file and a held file. Sam's agent starts the run with
  `start_analysis`, exactly as an agent does, and the held test keeps it going
  until a scenario releases or kills it.
  """

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CmsHarnessTest.ClusteredProject
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks

  # How long the run may take to reach its held test: a queue behind the
  # machine's analyzer slots and a `mix test` boot, on a loaded machine. Under
  # the spex timeout (`CodeMySpecSpex.Case.spex_timeout/0`, three minutes).
  @start_ms 120_000

  @doc """
  A live harness serving Sam's checkout with the watchable suite, and the run
  of it Sam's agent started, held open. Puts `:run_id` and `:os_pid` (the
  `mix test` running it) in `context`.
  """
  @spec start(map()) :: map()
  def start(context) do
    context = HarnessHooks.ensure_live_harness(context)
    :ok = ClusteredProject.make_suite(context.harness.root)
    start_run(context, "exunit")
  end

  @doc """
  Story 1144: `start/1` for credo. Sam's checkout is `ClusteredProject.make_credo/1`'s,
  and the run is held open by its own check until released or killed.
  """
  @spec start_credo(map()) :: map()
  def start_credo(context) do
    context = HarnessHooks.ensure_live_harness(context)
    :ok = ClusteredProject.make_credo(context.harness.root)
    start_run(context, "credo")
  end

  defp start_run(context, source) do
    agent = Fixtures.running_agent(context.scope, role: "coding")

    reply =
      ToolLibrary.run("start_analysis", %{source: source}, %{
        scope: context.scope,
        current_scope: context.scope,
        agent_id: agent.id
      })

    [_, run_id] = Regex.run(~r/Run (\d+) /, response_text(reply))

    Map.merge(context, %{
      run_id: String.to_integer(run_id),
      os_pid: ClusteredProject.await_running(context.harness.root, @start_ms)
    })
  end

  @doc "Where Sam watches the run."
  @spec path(map()) :: String.t()
  def path(%{scope: scope, run_id: run_id}),
    do: "/app/projects/#{scope.active_project_id}/runs/#{run_id}"

  @doc "Where Sam reads his problems."
  @spec problems_path(map()) :: String.t()
  def problems_path(%{scope: scope}), do: "/app/projects/#{scope.active_project_id}/problems"
end
