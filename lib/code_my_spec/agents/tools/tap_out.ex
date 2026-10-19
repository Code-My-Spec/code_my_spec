defmodule CodeMySpec.Agents.Tools.TapOut do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Notifications

  @impl true
  def name, do: "tap_out"

  @impl true
  def description do
    """
    Voluntary tap-out of continuous mode (Story 704 / Rule 5; consumer of
    538/5124).

    Writes a `PermissionRequest` the person sees in their notifications inbox,
    keyed to the agent we run or to the Claude Code session that asked. Returns
    immediately; the caller does not wait. On approve, continuous clears (or the
    linked task is cancelled). On reject, it stays on.
    """
  end

  @impl true
  def params do
    %{
      reason: {:meta, :string, [description: "Why this work should stop."]},
      session_id: {:meta, :string, [description: "Injected by hook — do not set manually"]},
      task_id:
        {:meta, :string,
         [description: "Task to block; omit for whole-agent continuous stop approval."]}
    }
  end

  @impl true
  # Durable requests live on the permission row, linked to a task only when
  # explicitly requested. A task blocker does not change continuous intent.
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, request} <- request(scope, context[:agent_id], params) do
      {:ok,
       """
       Tap-out requested (request_id=`#{request.id}`). The main agent decides it and
       sends it to your user only if it is theirs; the main agent's own goes to the user.

       A linked task is blocked; unrelated work may continue. Without a task,
       this asks to turn off continuous work upon approval. Do not ask again.
       """}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Tap-out was not saved: #{inspect(reason)}"}
    end
  rescue
    error ->
      {:error, "Tap-out was not saved: #{Exception.message(error)}"}
  end

  # A teammate's tap-out is main's to decide from the moment it is raised
  # (criteria 2073, 2120), so main is woken and offered it, as for a question.
  # A terminal session's is the person's, with nobody above it to route to.
  defp request(scope, agent_id, params) do
    with {:ok, agent} <- Agents.fetch_owner(scope, agent_id, params[:session_id]),
         {:ok, request} <-
           Notifications.request_agent_tap_out(scope, agent.id, params[:task_id], params[:reason]) do
      wake_main(scope, agent)
      {:ok, request}
    else
      {:error, :no_owner} -> {:error, Agents.no_owner_message() <> " Nothing was saved."}
      {:error, :not_found} -> {:error, "Agent not found in this project. Nothing was saved."}
      other -> other
    end
  end

  defp wake_main(_scope, %Agent{engine: :claude_code}), do: :ok

  defp wake_main(scope, %Agent{id: id}) do
    :ok = MainAgent.question_raised(scope, %{agent_id: id})
  end
end
