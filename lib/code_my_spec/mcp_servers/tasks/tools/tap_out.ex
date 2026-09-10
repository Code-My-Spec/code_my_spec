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
  end

  @impl true
  # An agent we run asks, stops, and is told what was decided.
  #
  # The session implementation writes its pending request into `session.state`
  # and a waiter polls it. An agent has no session to write into — and did not
  # need one: the permission request row *is* the pending state, and
  # `session.state` was a second copy of it for a waiter an agent does not have.
  #
  # So this is the same shape as `ask_user_question`: the request is published,
  # the tool returns, the agent stops, and `resolve_permission_request/2`
  # delivers the decision as a message. Denied is the case that matters — an
  # agent that asked to leave and heard nothing cannot tell a refusal from a
  # decision nobody has made yet.
  def execute(_params, %{assigns: %{agent_id: agent_id}} = frame)
      when is_binary(agent_id) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, request} <- request_agent_tap_out(scope, agent_id) do
      {:reply,
       Response.tool()
       |> Response.text("""
       Tap-out requested (request_id=`#{request.id}`). A human decides.

       Stop now. You will be told what was decided — approved and the loop is
       done, declined and you carry on from where you left off. Do not wait and
       do not ask again.
       """), frame}
    else
      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("#{inspect(reason)}"), frame}
    end
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

  # Idempotent, not a fresh ask. An agent that calls this again while its
  # first request is still pending is not asking twice — it is the same
  # question, asked because the loop handed it a menu that still offers
  # `tap_out` on every unrelated wake. A second row would be a second
  # decision for a human to make about a question already asked, and the
  # backlog that leaves behind never gets smaller.
  defp request_agent_tap_out(%{user: %{id: user_id}}, agent_id) do
    case Notifications.get_pending_tap_out_request(agent_id) do
      nil ->
        Notifications.create_permission_request(user_id, %{
          "agent_id" => agent_id,
          "tool_name" => "tap_out",
          "tool_input" => %{"agent_id" => agent_id}
        })

      existing ->
        {:ok, existing}
    end
  end

  defp request_agent_tap_out(_scope, _agent_id), do: {:error, :no_user}

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
