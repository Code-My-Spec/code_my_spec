defmodule CodeMySpec.Sessions.SessionStack do
  @moduledoc """
  Evaluates the session stack on stop hook.

  Reads all active sessions via SessionsRepository, sorts by priority
  (highest first), and calls each agent task module's evaluate function
  in order. The first evaluation that returns invalid blocks the agent
  with feedback. Passing evaluations remove the session. When no sessions
  remain, the agent stops cleanly.
  """

  alias CodeMySpec.Sessions.SessionsRepository
  alias CodeMySpec.Sessions.Session

  @doc """
  Evaluate the session stack and return a hook decision map.

  Called by the stop hook. Lists sessions, evaluates in priority order
  (highest first), and returns the first blocking result or an empty map
  if all pass.
  """
  @spec evaluate(CodeMySpec.Environments.Environment.t(), keyword()) :: map()
  def evaluate(env, opts \\ []) do
    case SessionsRepository.list_sessions(env) do
      {:ok, []} ->
        %{}

      {:ok, sessions} ->
        sessions
        |> Enum.sort_by(& &1.priority, :desc)
        |> evaluate_sessions(env, opts)
    end
  end

  defp evaluate_sessions([], _env, _opts), do: %{}

  defp evaluate_sessions([%Session{} = session | rest], env, opts) do
    module = session.type

    case call_evaluate(module, env, session, opts) do
      {:ok, :valid} ->
        SessionsRepository.delete_session(env, session.id)
        evaluate_sessions(rest, env, opts)

      {:ok, :invalid, feedback} ->
        %{"decision" => "block", "reason" => feedback}

      {:error, reason} ->
        %{"decision" => "block", "reason" => "Evaluation error: #{inspect(reason)}"}
    end
  end

  defp call_evaluate(module, _env, session, opts) do
    module.evaluate(nil, session.state || %{}, opts)
  rescue
    e -> {:error, Exception.message(e)}
  end
end
