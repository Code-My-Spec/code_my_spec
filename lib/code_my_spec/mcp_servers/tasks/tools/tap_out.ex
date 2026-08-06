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
  alias CodeMySpec.Permissions.TapOut
  alias CodeMySpec.Sessions

  schema do
    field :session_id, :string, doc: "Injected by hook — do not set manually"
  end

  @impl true
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
       "No session_id available. Call `register_session` with this conversation's id (CLAUDE_SESSION_ID) to create it on this server."}
end
