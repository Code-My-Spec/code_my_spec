defmodule CodeMySpec.McpServers.Tasks.Tools.TapOut do
  @moduledoc """
  Voluntary tap-out of continuous mode (Story 704 / Rule 5; consumer of
  538/5124).

  Publishes a permission request to PermissionSocket and returns
  immediately with a request_id. The agent does NOT block waiting for
  human approval. On approve, `session.continuous` clears (next stop
  hook will allow). On reject, the flag stays on.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Notifications
  alias CodeMySpec.Permissions.TapOut
  alias CodeMySpec.Sessions

  schema do
    field :session_id, :string, doc: "Injected by hook — do not set manually"
    field :task_id, :string, doc: "Task to block; omit for whole-agent continuous stop approval."
    field :reason, :string, doc: "Why this work should stop."
  end

  @impl true
  # Durable requests live on the permission row, linked to a task only when
  # explicitly requested. A task blocker does not change continuous intent.
  def execute(params, %{assigns: %{agent_id: agent_id}} = frame)
      when is_binary(agent_id) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, request} <-
           Notifications.request_agent_tap_out(scope, agent_id, params[:task_id], params[:reason]) do
      {:reply,
       Response.tool()
       |> Response.text("""
       Tap-out requested (request_id=`#{request.id}`). A human decides.

       A linked task is blocked; unrelated work may continue. Without a task,
       this asks to turn off continuous work upon approval. Do not ask again.
       """), frame}
    else
      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("#{inspect(reason)}"), frame}
    end
  rescue
    error ->
      {:reply,
       Response.tool() |> Response.error("Tap-out was not saved: #{Exception.message(error)}"),
       frame}
  end

  def execute(params, frame) do
    session_id = Map.get(params, :session_id)

    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, session} <- resolve_session(scope, session_id),
         {:ok, request_id} <- TapOut.request(scope, session) do
      msg =
        "Tap-out request published — awaiting human approval (request_id=`#{request_id}`). " <>
          "Continuous mode remains on until the human responds."

      {:reply, Response.tool() |> Response.text(msg), frame}
    else
      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("#{inspect(reason)}"), frame}
    end
  end

  defp resolve_session(scope, session_id) when is_binary(session_id) and session_id != "" do
    case Sessions.get_by_external_id(scope, session_id) do
      nil -> {:error, "Session not found: #{session_id}"}
      session -> {:ok, session}
    end
  end

  defp resolve_session(_scope, _),
    do:
      {:error,
       "`tap_out` is built on a Claude Code session — it writes the pending " <>
         "request into `session.state` — and an agent we run has no session to " <>
         "write into. So this is not something you can call yet, and not " <>
         "something a different spelling or a session id will fix.\n\n" <>
         "If you want out of the loop, say so in your reply and stop. A human " <>
         "reads that; nothing here does."}
end
