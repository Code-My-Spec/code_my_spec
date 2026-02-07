defmodule CodeMySpec.AgentTasks.EvaluateAgentTask do
  @moduledoc """
  Orchestrates evaluation of agent task sessions on stop hook.

  Implements priority-level evaluation:
  1. Evaluate ALL sessions at the highest priority level
  2. Delete passing ones, collect feedback from ALL invalid ones at that level
  3. If any invalid → block with combined concise feedback
  4. If all pass at that level → move to next priority level down
  5. Priority 0 (orchestrator) evaluates overall state, may create new level 1 tasks
  """

  alias CodeMySpec.Components
  alias CodeMySpec.Sessions
  alias CodeMySpec.Users.Scope

  @doc """
  Evaluate the session stack and return a hook decision map.

  Returns `%{}` when all sessions pass (or none exist),
  or `%{"decision" => "block", "reason" => feedback}` when any fail.
  """
  @spec run(Scope.t(), keyword()) :: map()
  def run(%Scope{} = scope, opts \\ []) do
    case Sessions.list_active_sessions(scope) do
      {:ok, []} -> %{}
      {:ok, sessions} -> evaluate_by_priority(sessions, scope, opts)
    end
  end

  defp evaluate_by_priority(sessions, scope, opts) do
    sessions
    |> Enum.group_by(& &1.priority)
    |> Enum.sort_by(fn {priority, _} -> priority end, :desc)
    |> evaluate_priority_levels(scope, opts)
  end

  defp evaluate_priority_levels([], _scope, _opts), do: %{}

  defp evaluate_priority_levels([{_priority, level_sessions} | rest], scope, opts) do
    results = Enum.map(level_sessions, &evaluate_one(scope, &1, opts))

    {passed, failed} = Enum.split_with(results, &match?({:ok, :valid, _session}, &1))

    # Delete passing sessions
    Enum.each(passed, fn {:ok, :valid, session} ->
      Sessions.delete_session(scope, session.id)
    end)

    case failed do
      [] ->
        evaluate_priority_levels(rest, scope, opts)

      failures ->
        build_combined_feedback(failures)
    end
  end

  defp evaluate_one(scope, session, opts) do
    session = enrich_session(scope, session)
    module = session.type

    case call_evaluate(module, scope, session, opts) do
      {:ok, :valid} -> {:ok, :valid, session}
      {:ok, :invalid, feedback} -> {:ok, :invalid, session, feedback}
      {:error, reason} -> {:ok, :invalid, session, "Error: #{inspect(reason)}"}
    end
  end

  defp enrich_session(scope, session) do
    component =
      if session.component_module_name do
        Components.get_component_by_module_name(scope, session.component_module_name)
      end

    %{session | component: component, project: scope.active_project}
  end

  defp call_evaluate(module, scope, session, opts) do
    module.evaluate(scope, session, opts)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_combined_feedback(failures) do
    reasons =
      failures
      |> Enum.map(fn
        {:ok, :invalid, session, feedback} ->
          type_name =
            session.type
            |> Atom.to_string()
            |> String.split(".")
            |> List.last()

          "[#{type_name}] #{feedback}"
      end)
      |> Enum.join("\n\n")

    %{"decision" => "block", "reason" => reasons}
  end
end
