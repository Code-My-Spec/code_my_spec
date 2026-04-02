defmodule CodeMySpec.AgentTasks.StartImplementation do
  @moduledoc """
  Enables continuous mode on the session.

  When continuous mode is active, the stop hook blocks the agent from
  stopping and directs it to `get_next_requirement` → `start_task`.
  The agent loop continues until all requirements are satisfied or
  continuous mode is disabled via `stop_implementation`.

  ## command/2
  Sets `state["continuous"] = true` on the session and returns a prompt
  telling the agent to call `get_next_requirement`.

  ## evaluate/2
  Checks if any actionable requirements remain. If none, returns :valid
  (continuous mode can be cleared). If work remains, returns :invalid
  with instructions to continue.
  """

  require Logger

  alias CodeMySpec.Requirements.RequirementGraph

  @spec command(term(), map()) :: {:ok, String.t()}
  def command(_scope, _task) do
    {:ok, """
    # Continuous Implementation Mode

    Continuous mode is now active. The stop hook will keep you working
    until all requirements are satisfied.

    Call `get_next_requirement` to find your next task, then `start_task` to begin.
    """}
  end

  @spec evaluate(term(), map()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()}
  def evaluate(scope, _task) do
    case RequirementGraph.next_actionable(scope) do
      [] ->
        {:ok, :valid}

      [node | _] ->
        task_name = node.satisfied_by |> inspect() |> String.split(".") |> List.last()

        {:ok, :invalid,
         "Work remaining: #{node.name} for #{node.entity_type} #{node.entity_name} (#{task_name}). " <>
           "Call `get_next_requirement` to continue."}
    end
  end
end
