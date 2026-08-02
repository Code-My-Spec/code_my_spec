defmodule CodeMySpec.Google.Auth do
  @moduledoc """
  Google's name for `Integrations.fetch_access_token/2`.

  This module used to own the refresh logic, and was the only provider that
  had any — Google's tokens expire in an hour, so the problem surfaced here
  first. Its two flaws only showed up when the same logic was needed four more
  times: it compared against the exact expiry, so a token with two seconds
  left passed and then failed mid-request; and it did not serialise, so
  concurrent callers both refreshed.

  Both are fixed in `Integrations.fetch_access_token/2`, which every provider
  now shares. This stays as a named entry point because Google's callers read
  better for it.
  """

  alias CodeMySpec.Integrations
  alias CodeMySpec.Users.Scope

  @doc """
  A Google access token that is valid now, refreshing first if needed.

  ## Returns

  - `{:ok, access_token}` — ready for a Bearer header
  - `{:error, :not_found}` — no Google integration on the scope
  - `{:error, :reauthorize_required}` — expired with nothing to refresh with
  - `{:error, reason}` — the provider refused the refresh
  """
  @spec get_valid_token(Scope.t()) :: {:ok, String.t()} | {:error, term()}
  def get_valid_token(%Scope{} = scope) do
    Integrations.fetch_access_token(scope, :google)
  end
end
