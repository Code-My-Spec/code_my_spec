defmodule CmsHarness.Agents.Tools.StartAnalysis do
  @moduledoc """
  Begin an analyzer run, carried directly.

  Excluded from scripts for the reason the other spawns are — a loop around it
  is a queue of sweeps nobody asked for — and therefore reachable by no route at
  all unless it is carried here. Same shape as `ask_user_question` and
  `tap_out` before it.

  It exists because the agent had no way to start a run. `FixBddSpecs` handed it
  `curl -X POST localhost:4004/api/harnesses/<id>/analysis/run`, and an agent in
  our own BEAM held that command open on a sweep that runs for minutes.

  A sync usually makes this unnecessary and that stays true: `sync_project`
  triggers a rescan, and changed files enqueue analysis on their own. This is
  for the case the external directive already named — nothing is running, so
  there is nothing to wait for.
  """

  use CmsHarness.Agents.Tools.Direct,
    name: "start_analysis",
    nothing_to: "no analyzers it can start"

  @impl true
  def description do
    """
    Start an analyzer run: `spex`, `exunit`, `credo` or `compiler`.

    Returns as soon as the run is opened. Do not wait for it and do not poll —
    stop when you have nothing else to do, and the result is delivered to you as
    a message when it lands.

    Usually you do not need this: editing files and calling `sync_project` will
    enqueue the analyzers by itself. Reach for it when a result is stale and
    nothing is running.
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        source: %{
          type: "string",
          enum: ["spex", "exunit", "credo", "compiler"],
          description: "Which analyzer to run."
        }
      },
      required: ["source"]
    }
  end
end
