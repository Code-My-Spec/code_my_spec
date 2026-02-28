defmodule CodeMySpec.Validation.TaskEvaluator do
  @moduledoc """
  Evaluates agent tasks. Two entry points for the two hook events:

  - `evaluate_component/2` resolves a component task from a transcript marker
    and delegates to the task module's `evaluate/3` (SubagentStop).
  - `evaluate_sessions/2` looks up sessions by external conversation ID,
    evaluates the session stack at highest priority, deletes passing sessions,
    and returns combined feedback for failures (Stop).
  """

  require Logger

  alias CodeMySpec.Components
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.SessionType
  alias CodeMySpec.Transcripts.TaskIdentifier
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils

  @doc """
  Resolve a component task from a transcript marker and evaluate it.

  Returns:
  - `{:ok, :valid}` when the task module passes
  - `{:ok, :invalid, feedback}` when the task module finds issues
  - `{:error, reason}` when the task module errors
  - `:none` when no marker found, type not recognized, or component not in DB
  """
  @spec evaluate_component(Scope.t(), keyword()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()} | {:error, String.t()} | :none
  def evaluate_component(%Scope{} = scope, opts) do
    transcript_path = Keyword.fetch!(opts, :transcript_path)

    case TaskIdentifier.identify(transcript_path) do
      {:ok, %{type: type_name, component: subject}} ->
        module = SessionType.mapper() |> Map.get(type_name)

        cond do
          is_nil(module) ->
            Logger.info("[TaskEvaluator] Unrecognized task type: #{type_name}")
            :none

          topic_based_task?(module) ->
            evaluate_topic_task(scope, module, subject)

          true ->
            evaluate_component_task(scope, module, subject)
        end

      :none ->
        :none
    end
  end

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
  # Component evaluation (SubagentStop)
  # ============================================================================

  @topic_based_tasks [CodeMySpec.AgentTasks.QaStory]

  defp topic_based_task?(module), do: module in @topic_based_tasks

  defp evaluate_topic_task(scope, module, subject) do
    session_map = %{
      project: scope.active_project,
      state: %{"topic" => subject}
    }

    call_evaluate(module, scope, session_map, [])
  end

  defp evaluate_component_task(scope, module, component_module_name) do
    case Components.get_component_by_module_name(scope, component_module_name) do
      nil ->
        Logger.info("[TaskEvaluator] Component not found: #{component_module_name}")
        :none

      component ->
        files = Utils.component_files(component, scope.active_project) |> Map.values()

        session_map = %{
          component: component,
          project: scope.active_project,
          files: files
        }

        call_evaluate(module, scope, session_map, [])
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
