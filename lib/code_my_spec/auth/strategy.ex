defmodule CodeMySpec.Auth.Strategy do
  @moduledoc """
  OAuth2 strategy for CodeMySpec server.
  """
  use OAuth2.Strategy

  alias OAuth2.Strategy.AuthCode
  alias OAuth2.Strategy.Refresh

  def authorize_url(client, params) do
    AuthCode.authorize_url(client, params)
  end

  def get_token(client, params, headers) when is_list(params) do
    client = put_header(client, "accept", "application/json")

    case Keyword.get(params, :grant_type) do
      "refresh_token" ->
        Refresh.get_token(client, params, headers)

      _ ->
        AuthCode.get_token(client, params, headers)
    end
  end
end
