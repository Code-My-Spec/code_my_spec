defmodule CodeMySpec.Integrations.Providers.OpenAI do
  @moduledoc """
  The ChatGPT subscription an agent runs on, held as an integration.

  ## The client id is OpenAI's, because there is no other kind

  `app_EMoamEEZ73f0CkXaXp7hrann` is OpenAI's Codex CLI client, embedded in that
  binary and copied by Pi and every other harness offering ChatGPT sign-in.
  OpenAI documents no third-party OAuth registration for subscription sign-in —
  checked, not assumed — and `originator` exists precisely because the model is
  one shared client with tools naming themselves as they use it.

  So the redirects are theirs too: `http://localhost:1455/auth/callback` and
  `https://auth.openai.com/deviceauth/callback`. A hosted callback of ours
  cannot be registered against a client we do not own, which is why connecting
  goes through `DeviceAuth` rather than `/auth/openai/callback` like the others.

  Confirmed by trying it: an authorize request naming our own redirect comes
  back `invalid_authorize_request`.

  ## Device code, everywhere, on purpose

  The browser flow is reproducible — Pi binds 1455 and catches the callback, and
  so could the local app. It is not the path, because the app is not always on
  the device the human is sitting at. One flow that works in every situation
  beats a faster one that works in some, and the device flow needs no listener,
  no port and no browser on the same machine.

  Note for whoever hits it: device authorization has to be **enabled on the
  OpenAI account** before the flow will start.

  ## Public client, no secret

  `auth_method: nil` and PKCE. OpenAI's OAuth is a public-client flow — the
  exchange posts `client_id` and `code_verifier` and no secret — so configuring
  one would be rejected rather than ignored.

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

  @auth_base "https://auth.openai.com"

  @impl true
  def config do
    [
      client_id: client_id(),
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

  @doc "OpenAI's Codex client. See the moduledoc — there is no other kind."
  @spec client_id() :: String.t()
  def client_id,
    do: Application.get_env(:code_my_spec, :openai_client_id, "app_EMoamEEZ73f0CkXaXp7hrann")

  defp build_redirect_uri do
    "#{CodeMySpec.PublicUrl.base()}/auth/openai/callback"
  end
end
