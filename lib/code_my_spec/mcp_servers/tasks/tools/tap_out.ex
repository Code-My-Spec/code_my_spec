defmodule CodeMySpec.McpServers.Tasks.Tools.TapOut do
  @moduledoc """
  Voluntary tap-out of continuous mode (Story 704 / Rule 5; consumer of
  538/5124).

  Writes a `PermissionRequest` the person sees in their notifications inbox,
  keyed to the agent we run or to the Claude Code session that asked. Returns
  immediately; the caller does not wait. On approve, continuous clears (or the
  linked task is cancelled). On reject, it stays on.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Notifications
  alias CodeMySpec.Sessions

  schema do
    field :session_id, :string, doc: "Injected by hook — do not set manually"
    field :task_id, :string, doc: "Task to block; omit for whole-agent continuous stop approval."
    field :reason, :string, doc: "Why this work should stop."
  end

  @impl true
  # Durable requests live on the permission row, linked to a task only when
  # explicitly requested. A task blocker does not change continuous intent.
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, request} <- request(scope, frame.assigns[:agent_id], params) do
      {:reply,
       Response.tool()
       |> Response.text("""
       Tap-out requested (request_id=`#{request.id}`). The main agent decides it and
       sends it to your user only if it is theirs; the main agent's own goes to the user.

       A linked task is blocked; unrelated work may continue. Without a task,
       this asks to turn off continuous work upon approval. Do not ask again.
       """), frame}
    else
      {:error, reason} when is_binary(reason) ->
        {:reply, Response.tool() |> Response.error(reason), frame}

      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("Tap-out was not saved: #{inspect(reason)}"),
         frame}
    end
  rescue
    error ->
      {:reply,
       Response.tool() |> Response.error("Tap-out was not saved: #{Exception.message(error)}"),
       frame}
  end

  # A teammate's tap-out is main's to decide from the moment it is raised
  # (criteria 2073, 2120), so main is woken and offered it, as for a question.
  defp request(scope, agent_id, params) when is_binary(agent_id) do
    with {:ok, request} <-
           Notifications.request_agent_tap_out(scope, agent_id, params[:task_id], params[:reason]) do
      :ok = MainAgent.question_raised(scope, %{agent_id: agent_id})
      {:ok, request}
    end
  end

  defp request(scope, _agent_id, params) do
    with {:ok, session} <- resolve_session(scope, params[:session_id]) do
      Notifications.request_session_tap_out(scope, session.id, params[:task_id], params[:reason])
    end
  end

  defp resolve_session(scope, session_id) when is_binary(session_id) and session_id != "" do
    case Sessions.get_by_external_id(scope, session_id) do
      nil -> {:error, "Session not found: #{session_id}. Nothing was saved."}
      session -> {:ok, session}
    end
  end

  defp resolve_session(_scope, _),
    do:
      {:error,
       "`tap_out` needs the session id the hook injects, and none arrived, so " <>
         "nothing was saved and no one was asked. If you want out of the loop, " <>
         "say so in your reply and stop; a human reads that."}
end
