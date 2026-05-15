defmodule CodeMySpec.Permissions.TapOut do
  @moduledoc """
  Voluntary tap-out of continuous mode (Story 704 / Rule 5).

  The agent calls the `tap_out` MCP tool, which invokes `request/2`.
  This module forwards the request to the production server as a
  `PermissionRequest` (`tool_name: "tap_out"`), records a pending
  entry on the local session, and starts a `TapOutWaiter` task that
  blocks on production's `permission:<id>` channel for the decision.

  When the human approves/denies via `PermissionLive.Show` on
  production, the waiter calls `respond/4`, which either clears
  `session.continuous` (approve) or leaves it on (reject), and
  broadcasts the decision on the `permissions:tap_out` PubSub topic.

  The MCP call returns immediately with the production-issued
  `request_id`; the agent does not block.
  """

  require Logger

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Permissions.TapOutWaiter
  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Users.Scope

  @topic "permissions:tap_out"

  @doc """
  Register a tap-out request on the session.

  Forwards the request to the production server, stores
  `%{"id" => request_id, "status" => "pending"}` under
  `session.state["pending_tap_out"]`, spawns a `TapOutWaiter` to
  apply the eventual decision, and broadcasts
  `{:tap_out_requested, request_id, session_id}` to subscribers of
  `permissions:tap_out`. Returns `{:ok, request_id}` immediately.
  """
  @spec request(Scope.t(), Session.t()) :: {:ok, String.t()} | {:error, term()}
  def request(%Scope{} = scope, %Session{} = session) do
    {request_id, remote?} = resolve_request_id(session)

    pending = %{
      "id" => request_id,
      "status" => "pending",
      "requested_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    new_state = Map.put(session.state || %{}, "pending_tap_out", pending)

    case Sessions.update_session(scope, session, %{state: new_state}) do
      {:ok, _updated} ->
        if remote?,
          do: maybe_start_waiter(scope, session.external_conversation_id, request_id)

        Phoenix.PubSub.broadcast(
          CodeMySpec.PubSub,
          @topic,
          {:tap_out_requested, request_id, session.external_conversation_id}
        )

        {:ok, request_id}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Tries to register the request with the production server so the
  # human can approve via PermissionLive.Show. On any failure (no
  # OAuth token, transport error, non-2xx) we fall back to a local
  # UUID — the pending entry is still recorded and `respond/4` still
  # works for tests / programmatic resolution; only the remote
  # approval channel is unavailable. `remote?` controls whether the
  # waiter is spawned.
  defp resolve_request_id(%Session{} = session) do
    case create_remote_request(session) do
      {:ok, id} -> {id, true}
      {:error, _} -> {Ecto.UUID.generate(), false}
    end
  end

  defp create_remote_request(%Session{} = session) do
    with {:ok, token} <- OAuthClient.get_token() do
      server_url = OAuthClient.get_server_url()
      url = "#{server_url}/api/permissions/request"
      headers = [{"authorization", "Bearer #{token}"}]

      body = %{
        tool_name: "tap_out",
        tool_input: %{
          session_id: session.external_conversation_id,
          session_db_id: session.id
        }
      }

      case Req.post(url, headers: headers, json: body) do
        {:ok, %{status: status, body: %{"id" => id}}} when status in [200, 201] ->
          {:ok, id}

        {:ok, %{status: status, body: body}} ->
          Logger.warning("[TapOut] remote create failed (status=#{status}): #{inspect(body)}")
          {:error, {:remote_http, status}}

        {:error, reason} ->
          Logger.warning("[TapOut] remote create transport error: #{inspect(reason)}")
          {:error, {:remote_transport, reason}}
      end
    end
  end

  defp maybe_start_waiter(_scope, nil, _request_id), do: :ok

  defp maybe_start_waiter(scope, session_id, request_id) do
    case TapOutWaiter.start(scope, session_id, request_id) do
      {:ok, _pid} -> :ok
      other ->
        Logger.warning("[TapOut] failed to start waiter for #{request_id}: #{inspect(other)}")
        :ok
    end
  end

  @doc """
  Apply a human decision to a pending tap-out request.

  - `:approve` — clears `session.continuous`, marks the pending
    record as `"approved"`, broadcasts `{:tap_out_decision, id, :approve}`.
  - `:reject` — leaves `session.continuous` unchanged, marks the
    pending record as `"rejected"`, broadcasts the rejection.

  Returns `{:ok, session}` on success.
  """
  @spec respond(Scope.t(), Session.t(), String.t(), :approve | :reject) ::
          {:ok, Session.t()} | {:error, term()}
  def respond(%Scope{} = scope, %Session{} = session, request_id, decision)
      when decision in [:approve, :reject] do
    case validate_pending(session, request_id) do
      :ok ->
        attrs = decision_attrs(session, request_id, decision)

        with {:ok, updated} <- Sessions.update_session(scope, session, attrs) do
          Phoenix.PubSub.broadcast(
            CodeMySpec.PubSub,
            @topic,
            {:tap_out_decision, request_id, decision}
          )

          {:ok, updated}
        end

      error ->
        error
    end
  end

  defp validate_pending(session, request_id) do
    case get_in(session.state || %{}, ["pending_tap_out"]) do
      %{"id" => ^request_id, "status" => "pending"} -> :ok
      %{"id" => ^request_id, "status" => status} -> {:error, "Already #{status}"}
      _ -> {:error, "No pending tap-out request matching id"}
    end
  end

  defp decision_attrs(session, _request_id, :approve) do
    pending = get_in(session.state || %{}, ["pending_tap_out"])
    updated_pending = Map.put(pending, "status", "approved")
    new_state = Map.put(session.state || %{}, "pending_tap_out", updated_pending)
    %{state: new_state, continuous: false}
  end

  defp decision_attrs(session, _request_id, :reject) do
    pending = get_in(session.state || %{}, ["pending_tap_out"])
    updated_pending = Map.put(pending, "status", "rejected")
    new_state = Map.put(session.state || %{}, "pending_tap_out", updated_pending)
    %{state: new_state}
  end

  @doc "Returns the PubSub topic clients subscribe to for tap-out events."
  def topic, do: @topic

  # Suppress "unused alias" — Repo is documented as the durable store
  # this module relies on via the Sessions context.
  _ = Repo
end
