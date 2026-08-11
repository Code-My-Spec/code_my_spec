defmodule CodeMySpec.McpServers.Tasks.Tools.RegisterSession do
  @moduledoc """
  Register this conversation as a session on the server.

  Every task tool hangs off a session, and normally the SessionStart hook
  creates it — the agent never thinks about it. That hook posts to the harness
  on localhost, so a server the harness is not reporting to has no session for
  the conversation, and every task tool dead-ends on `No session_id available`
  with nothing the agent can do about it.

  Deliberately explicit rather than implicit. A tool that silently invents a
  session on first use hides which server the work is being recorded against,
  and that is exactly the thing worth being sure of when two of them are
  reachable. The task tools name this one in their error instead.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Sessions

  schema do
    field :session_id, :string,
      required: true,
      doc: "This conversation's id — Claude Code exposes it as CLAUDE_SESSION_ID"
  end

  @impl true
  def execute(params, frame) do
    session_id = Map.get(params, :session_id)

    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, session} <- register(scope, session_id) do
      {:reply, Response.tool() |> Response.text(describe(session, session_id)), frame}
    else
      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("#{reason}"), frame}
    end
  end

  defp register(_scope, id) when not is_binary(id) or id == "",
    do: {:error, "session_id is required — pass this conversation's CLAUDE_SESSION_ID"}

  defp register(scope, session_id) do
    case Sessions.find_or_create_session(scope, session_id) do
      {:ok, session} ->
        {:ok, session}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, "Could not register session #{session_id}: #{inspect(changeset.errors)}"}
    end
  end

  # Says which project it landed against: the whole reason this is explicit is
  # so the agent can tell one server from another.
  defp describe(session, session_id) do
    """
    Session registered: #{session_id}

    Project: #{session.project_id}
    Task tools on this server will now resolve against it.#{build_line()}
    """
  end

  # Which commit this server is running.
  #
  # A dev server runs the checkout it was started from, so a fix that is
  # committed, pushed and green can be absent from every response an agent sees.
  # The responses that matter here are messages about correctness — a stale
  # stop-hook sentence, a missing reproduce line — and an agent reading one does
  # not conclude "the server is behind", it concludes the fix does not work and
  # re-investigates something already closed (5e59a29d).
  #
  # Said once, at registration, rather than on every response: it is a fact about
  # the session, and repeating it would be noise until the moment it is not.
  defp build_line do
    case CodeMySpec.BootVersion.booted() do
      nil -> ""
      sha -> "\n\nServer build: #{sha}"
    end
  end
end
