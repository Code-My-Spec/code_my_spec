defmodule CodeMySpec.AgentTasks.StartImplementation do
  @moduledoc """
  Enables continuous mode on the session and prompts the agent to begin
  the autonomous implementation loop.

  When continuous mode is active, the stop hook blocks the agent from
  stopping and directs it to the next requirement. The loop continues
  until all requirements are satisfied or continuous mode is cleared.

  ## init_session/2
  Owns the per-task session setup. Sets the materialized `continuous`
  boolean on the session via `Sessions.update_session/3`. Both entry
  points (the CLI orchestrator in `StartAgentTask` and the `start_task`
  MCP tool) dispatch to this so the per-task setup lives in the task
  module rather than being duplicated at every call site.

  ## command/2
  Returns the kickoff prompt. Does not mutate state — `init_session/2`
  has already run by the time `command/2` is called.

  ## evaluate/2
  Checks if any actionable requirements remain. If none, returns `:valid`
  (continuous mode can be cleared). If work remains, returns `:invalid`
  with instructions to continue.
  """


  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  @spec init_session(term(), Session.t()) :: {:ok, Session.t()} | {:error, term()}
  def init_session(scope, session) do
    Sessions.update_session(scope, session, %{continuous: true})
  end

  @spec command(term(), map()) :: {:ok, String.t()}
  def command(_scope, _task) do
    {:ok,
     """
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
