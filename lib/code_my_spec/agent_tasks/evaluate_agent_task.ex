defmodule CodeMySpec.AgentTasks.EvaluateAgentTask do
  @moduledoc """
  Orchestrates evaluation of agent task sessions on stop hook.

  Evaluates all sessions at the highest priority level (returned by SessionStack).
  Deletes passing ones, blocks with combined feedback if any are invalid.
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
      {:ok, sessions} -> evaluate_level(sessions, scope, opts)
    end
  end

  defp evaluate_level(sessions, scope, opts) do
    results = Enum.map(sessions, &evaluate_one(scope, &1, opts))

    {passed, failed} = Enum.split_with(results, &match?({:ok, :valid, _session}, &1))

    # Delete passing sessions
    Enum.each(passed, fn {:ok, :valid, session} ->
      Sessions.delete_session(scope, session.id)
    end)

    case failed do
      [] -> %{}
      failures -> build_combined_feedback(failures)
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
      |> Enum.map_join("\n\n", fn
        {:ok, :invalid, session, feedback} ->
          type_name =
            session.type
            |> Atom.to_string()
            |> String.split(".")
            |> List.last()

          "[#{type_name}] #{feedback}"
      end)

    %{"decision" => "block", "reason" => reasons}
  end
end
