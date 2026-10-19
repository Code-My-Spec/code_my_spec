defmodule CodeMySpecWeb.DeviceAuthorizationController do
  @moduledoc """
  OAuth 2.0 Device Authorization Grant (RFC 8628).

  John's decision, issue 94cb8e04: a harness authenticates as its own OAuth
  client rather than borrowing a project's deploy key. Dynamic client
  registration (`/oauth/register`, already served) gives the harness a
  `client_id`; this is the flow that turns that registration into a token
  without ever putting an attached browser on the harness's own box --
  the harness shows a code and a URL, a person opens it anywhere they
  already have a session, and the harness polls `/oauth/token` until they
  decide.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Oauth
  alias CodeMySpec.Oauth.DeviceGrant

  @doc """
  POST /oauth/device/code

  The harness's first call: names its own `client_id` (from dynamic client
  registration) and its own `device_id`, and gets back the pair of codes
  RFC 8628 describes -- `device_code` to poll `/oauth/token` with,
  `user_code` to show the person.
  """
  def create(conn, params) do
    case Oauth.request_device_code(params["client_id"], params["device_id"]) do
      {:ok, grant} ->
        json(conn, %{
          device_code: grant.device_code,
          user_code: grant.user_code,
          verification_uri: verification_uri(),
          verification_uri_complete: verification_uri_complete(grant.user_code),
          expires_in: DateTime.diff(grant.expires_at, DateTime.utc_now()),
          interval: grant.interval
        })

      {:error, :invalid_client} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_client"})

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "server_error"})
    end
  end

  @doc """
  GET /oauth/device

  The verification page a person opens (from the harness's own printed URL,
  or by typing `user_code` in by hand). Unauthenticated, it is the ordinary
  login redirect every browser-facing OAuth page in this app already uses.
  """
  def new(conn, params) do
    case conn.assigns[:current_scope] do
      nil ->
        return_to = "/oauth/device?" <> URI.encode_query(params)

        conn
        |> put_session(:user_return_to, return_to)
        |> redirect(to: ~p"/users/log-in")

      _scope ->
        render(conn, :new, user_code: params["user_code"], grant: nil, error: nil)
    end
  end

  @doc """
  POST /oauth/device

  Looks the typed-in `user_code` up and shows what it is about to approve --
  a separate step from `decide/2` so a person sees the application's name
  before committing, the same two-step shape `/oauth/authorize` already
  uses.
  """
  def show(conn, %{"user_code" => user_code} = _params) do
    case Oauth.get_device_grant_by_user_code(user_code) do
      nil ->
        render(conn, :new, user_code: user_code, grant: nil, error: "That code was not found.")

      %DeviceGrant{} = grant ->
        cond do
          DeviceGrant.expired?(grant) ->
            render(conn, :new,
              user_code: user_code,
              grant: nil,
              error: "That code has expired. Ask the device for a new one."
            )

          DeviceGrant.denied?(grant) or DeviceGrant.approved?(grant) ->
            render(conn, :new,
              user_code: user_code,
              grant: nil,
              error: "That code was already used."
            )

          true ->
            render(conn, :confirm, grant: grant)
        end
    end
  end

  @doc """
  POST /oauth/device/decide

  The person's actual decision, once they have seen the application's name
  on the confirm page. `device_code` rather than `user_code` here -- it is
  hidden in the confirm form, not retyped, so there is one lookup and one
  grant for the whole visit.
  """
  def decide(conn, %{"device_code" => device_code, "decision" => decision}) do
    scope = conn.assigns.current_scope

    with {:ok, grant} <- fetch_by_device_code(device_code),
         {:ok, action} <- decision_atom(decision),
         {:ok, _grant} <- Oauth.decide_device_grant(grant, scope.user, action) do
      render(conn, :decided, approved?: action == :approve)
    else
      {:error, reason} ->
        render(conn, :new, user_code: nil, grant: nil, error: decision_error(reason))
    end
  end

  defp fetch_by_device_code(device_code) do
    case Oauth.get_device_grant_by_device_code(device_code) do
      nil -> {:error, :not_found}
      grant -> {:ok, grant}
    end
  end

  defp decision_atom("approve"), do: {:ok, :approve}
  defp decision_atom("deny"), do: {:ok, :deny}
  defp decision_atom(_other), do: {:error, :invalid_decision}

  defp decision_error(:not_found), do: "That code was not found."
  defp decision_error(:invalid_decision), do: "That was not a valid decision."
  defp decision_error(:expired), do: "That code has expired. Ask the device for a new one."
  defp decision_error(:already_decided), do: "That code was already used."
  defp decision_error(_other), do: "Something went wrong. Try again."

  defp verification_uri, do: CodeMySpecWeb.Endpoint.url() <> "/oauth/device"

  defp verification_uri_complete(user_code),
    do: verification_uri() <> "?" <> URI.encode_query(%{"user_code" => user_code})
end
