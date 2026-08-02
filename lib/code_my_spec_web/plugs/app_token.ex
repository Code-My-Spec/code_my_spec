defmodule CodeMySpecWeb.Plugs.AppToken do
  @moduledoc """
  Authenticates a deployed app by a short-lived access token.

  ## It refuses the refresh secret on purpose

  The refresh secret buys a token and nothing else (criterion 8046). If this
  plug accepted it as a bearer credential, the durable secret in the app's
  environment would open every surface directly and the whole exchange would
  be decoration — which is exactly what criterion 8045 asserts is not true.

  So a refresh secret presented here fails like any other unrecognised
  credential. That is the property, not an oversight.

  ## The refusal says which kind

  `expired` and `invalid` are different answers, and the response carries
  `reason` so a client can tell them apart (criterion 8023). One means "renew
  and retry"; the other means "your credential is wrong, stop retrying".
  Collapsing them is how a client hammers a token endpoint over a typo.
  """

  import Plug.Conn

  alias CodeMySpec.AppTokens

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> authenticate(conn, token)
      _ -> refuse(conn, :invalid)
    end
  end

  defp authenticate(conn, token) do
    case AppTokens.verify(token) do
      {:ok, project} ->
        conn
        |> assign(:app_token_project, project)
        |> assign(:app_token_project_id, project.id)

      {:error, reason} ->
        refuse(conn, reason)
    end
  end

  # 401 rather than 403: the credential is the problem, not the permission,
  # and a client that reads status alone should still be told to re-authenticate.
  defp refuse(conn, reason) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{"error" => "unauthorized", "reason" => to_string(reason)}))
    |> halt()
  end
end
