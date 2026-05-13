defmodule CodeMySpec.Permissions.TapOut do
  @moduledoc """
  Voluntary tap-out of continuous mode (Story 704 / Rule 5).

  The agent calls the `tap_out` MCP tool; this module records a
  pending request on the session and broadcasts to the
  `permissions:tap_out` PubSub topic so the production webhook /
  human-approval flow can pick it up. The MCP call returns
  immediately with a `request_id`; the agent does not block.

  When the human responds, the calling surface invokes `respond/4`
  which either clears `session.continuous` (approve) or leaves it on
  (reject), and broadcasts the decision.

  The production-side webhook delivery is wired by the
  `PermissionController` and `PermissionSocket` modules (Story 538's
  `hooks.json` already configures the `PermissionRequest` event).
  This module only owns the local state + PubSub surface.
  """

  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Users.Scope

  @topic "permissions:tap_out"

  @doc """
  Register a tap-out request on the session.

  Stores `%{"id" => uuid, "status" => "pending"}` under
  `session.state["pending_tap_out"]` and broadcasts
  `{:tap_out_requested, request_id, session_id}` to subscribers of
  `permissions:tap_out`. Returns `{:ok, request_id}` immediately.
  """
  @spec request(Scope.t(), Session.t()) :: {:ok, String.t()} | {:error, term()}
  def request(%Scope{} = scope, %Session{} = session) do
    request_id = Ecto.UUID.generate()

    pending = %{
      "id" => request_id,
      "status" => "pending",
      "requested_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    new_state = Map.put(session.state || %{}, "pending_tap_out", pending)

    case Sessions.update_session(scope, session, %{state: new_state}) do
      {:ok, _updated} ->
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

  defp decision_attrs(session, request_id, :approve) do
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
