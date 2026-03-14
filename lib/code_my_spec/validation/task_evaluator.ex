defmodule CodeMySpec.Validation.TaskEvaluator do
  @moduledoc """
  Evaluates agent tasks via the Stop hook.

  `evaluate_sessions/2` looks up sessions by external conversation ID,
  evaluates the session stack at highest priority, deletes passing sessions,
  and returns combined feedback for failures.

  SubagentStop task identification is handled by
  `ImplementationStatus.identify_task_from_transcript/2` and
  `Validation.identify_and_evaluate_task/2` instead.
  """

  require Logger

  alias CodeMySpec.Components
  alias CodeMySpec.Sessions
  alias CodeMySpec.Users.Scope

  @doc """
  Look up sessions by external conversation ID, evaluate the session stack,
  delete passing sessions, and return combined feedback for failures.
  """
  @spec evaluate_sessions(Scope.t(), String.t()) :: {:ok, :valid} | {:error, String.t()}
  def evaluate_sessions(%Scope{} = scope, session_id) when is_binary(session_id) do
    case Sessions.list_sessions(scope) do
      {:ok, all_sessions} ->
        sessions =
          all_sessions
          |> Enum.filter(&(&1.external_conversation_id == session_id))

        if sessions == [] do
          {:ok, :valid}
        else
          evaluate_session_stack(scope, sessions)
        end

      _error ->
        {:ok, :valid}
    end
  end

  # ============================================================================
  # Session stack evaluation (Stop)
  # ============================================================================

  defp evaluate_session_stack(scope, sessions) do
    # Get sessions at highest priority level
    max_priority = sessions |> Enum.map(& &1.priority) |> Enum.max()
    top_sessions = Enum.filter(sessions, &(&1.priority == max_priority))

    results = Enum.map(top_sessions, &evaluate_one_session(scope, &1))

    {passed, failed} = Enum.split_with(results, &match?({:ok, :valid, _}, &1))

    # Delete passing sessions
    Enum.each(passed, fn {:ok, :valid, session} ->
      Sessions.delete_session(scope, session.id)
    end)

    case failed do
      [] ->
        {:ok, :valid}

      failures ->
        feedback = build_combined_feedback(failures)
        {:error, feedback}
    end
  end

  defp evaluate_one_session(scope, session) do
    session = enrich_session(scope, session)
    module = session.type

    type_name = module |> Atom.to_string() |> String.split(".") |> List.last()
    Logger.info("[TaskEvaluator] Evaluating session #{session.id} (#{type_name})")

    case call_evaluate(module, scope, session, []) do
      {:ok, :valid} ->
        {:ok, :valid, session}

      {:ok, :invalid, feedback} ->
        {:ok, :invalid, session, feedback}

      {:error, reason} ->
        {:ok, :invalid, session, "Error: #{inspect(reason)}"}
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
    e ->
      {:error, "Task evaluation failed: #{Exception.message(e)}"}
  end

  defp build_combined_feedback(failures) do
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
  end
end
