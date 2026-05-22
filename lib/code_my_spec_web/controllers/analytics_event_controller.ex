defmodule CodeMySpecWeb.AnalyticsEventController do
  @moduledoc """
  Receives browser-originated analytics events and forwards them to
  `CodeMySpec.Analytics.dispatch/3` for server-side delivery to GA4
  via the Measurement Protocol.

  Replaces the previous pattern of firing `gtag('event', …)` directly
  from the client. Keeps the GA4 measurement_id and API secret on the
  server, and gives every event the same telemetry fan-out as
  server-originated events.

  CSRF-protected via the `:browser_json` pipeline — callers must send
  the `x-csrf-token` header (already wired in `app.js`).
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Analytics

  # `String.to_existing_atom/1` is the atom-safety gate — untrusted
  # browser input cannot grow the atom table. Listing the
  # browser-fireable event names here guarantees the BEAM has them
  # loaded before any HTTP request arrives, so legitimate events
  # resolve even on a freshly-booted node. This is NOT an allowlist;
  # any atom present anywhere in the codebase will also resolve.
  @browser_event_names [
    :deep_content_read,
    :install_command_copy,
    :install_step_copied,
    :onboarding_panel_viewed,
    :view_register_page,
    :registration_form_start,
    :registration_path_chosen,
    :oauth_github_clicked,
    :oauth_google_clicked
  ]
  @doc false
  def __browser_event_names__, do: @browser_event_names

  def create(conn, %{"name" => name} = params) when is_binary(name) and name != "" do
    event_params = params |> Map.get("params", %{}) |> stringify_params() |> attach_user(conn)

    case to_event_name(name) do
      {:ok, event_name} ->
        Analytics.dispatch(event_name, event_params, :server)
        json(conn, %{status: "ok"})

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid event name"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "missing event name"})
  end

  # Server-side `Analytics.dispatch/3` expects an atom event name and
  # the downstream GA payload code uses `to_string/1` on it. Avoid
  # `String.to_atom/1` so untrusted browser input can't grow the atom
  # table — restrict to atoms that already exist in the VM (i.e. names
  # this codebase has dispatched somewhere).
  defp to_event_name(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end

  defp stringify_params(params) when is_map(params) do
    Map.new(params, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_params(_), do: %{}

  defp attach_user(params, %{assigns: %{current_scope: %{user: %{id: user_id}}}})
       when not is_nil(user_id) do
    Map.put_new(params, "user_id", user_id)
  end

  defp attach_user(params, _conn), do: params
end
