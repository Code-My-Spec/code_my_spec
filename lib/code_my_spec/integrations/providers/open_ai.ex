defmodule CodeMySpec.Integrations.Providers.OpenAI do
  @moduledoc """
  The ChatGPT subscription an agent runs on, held as an integration.

  ## This is Pi's OAuth client, on purpose

  `client_id` is `app_EMoamEEZ73f0CkXaXp7hrann` — Pi's own, read from
  `pi-ai/dist/auth/oauth/openai-codex.js`. That is not a shortcut around
  registering our own: a refresh token is bound to the client it was issued to,
  and the credential we hold is one Pi minted and one Pi will spend. A token
  issued to a different client would not refresh here and would not be accepted
  there.

  The consequence worth stating: we can refresh this grant and we cannot mint
  one. `/login` is a TUI slash command with no CLI entry point, so the first
  grant is made by a human through Pi and recorded here afterwards. There is a
  device-code flow (`openai-codex.js:419`, labelled "headless") that needs no
  local browser, which is the route worth taking if minting ever has to happen
  off-box.

  ## Public client, no secret

  `auth_method: nil` and PKCE. OpenAI's Codex client is public — the exchange
  posts `client_id` and `code_verifier` and no secret — so configuring one would
  be rejected rather than ignored.

  ## Refresh tokens rotate

  `readTokenResponse/2` requires `refresh_token` in the *refresh* response and
  stores it, so every refresh supersedes the previous token.
  `Integrations.refresh_token/2` already persists a rotated one.

  The part that is not handled here, and is recorded on story 1018 rather than
  solved: two working copies seeded from one credential can refresh out of
  order, and a public client using rotation is the exact case the OAuth 2.0
  Security BCP tells providers to treat as replay and revoke the whole grant
  over. If OpenAI follows it, one stale copy takes the family down and the
  symptom arrives here as a credential that will not refresh.
  """

  @behaviour CodeMySpec.Integrations.Providers.Behaviour

  # Pi's client. See the moduledoc — a refresh token is bound to its issuer, so
  # this has to match the client that minted the grant.
  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"

  @auth_base "https://auth.openai.com"

  @impl true
  def config do
    [
      client_id: Application.get_env(:code_my_spec, :openai_client_id, @client_id),
      base_url: @auth_base,
      authorize_url: "/oauth/authorize",
      token_url: "/oauth/token",
      # There is no user endpoint on this grant. Identity travels inside the
      # access token as `chatgpt_account_id`, which is how Pi reads it too.
      user_url: nil,
      auth_method: nil,
      code_verifier: true,
      redirect_uri: build_redirect_uri()
    ]
  end

  @impl true
  def strategy, do: Assent.Strategy.OAuth2

  @doc "The scopes this integration requests."
  @spec scopes() :: [String.t()]
  def scopes, do: []

  # No `/me` to call, so identity comes from the token rather than a request.
  # A grant that does not carry an account id is still usable — the agent runs
  # on the token, not on the label — so this must not error.
  @impl true
  def normalize_user(user) when is_map(user) do
    {:ok,
     %{
       provider_user_id: user["chatgpt_account_id"] || user["sub"],
       email: user["email"],
       name: "ChatGPT subscription"
     }}
  end

  defp build_redirect_uri do
    "#{CodeMySpec.PublicUrl.base()}/auth/openai/callback"
  end
end
