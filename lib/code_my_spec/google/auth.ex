defmodule CodeMySpec.Google.Auth do
  @moduledoc """
  Shared Google OAuth token resolution. Looks up the scope's Google
  integration, refreshes the access token if it's past its
  `expires_at`, and returns a valid token for use as an
  `Authorization: Bearer ...` header.

  Used by both `CodeMySpec.Google.Analytics` (Tesla-wrapped admin API
  client) and `CodeMySpec.Analytics.GoogleAnalytics.ReportingClient`
  (Req-based data API client). Centralized so refresh logic only
  lives in one place.
  """

  alias CodeMySpec.Integrations
  alias CodeMySpec.Integrations.Integration
  alias CodeMySpec.Users.Scope

  @doc """
  Resolves a valid Google access token for the given scope.

  Looks up the Google integration on the scope. If the integration's
  token is expired, refreshes it via Integrations.refresh_token/2 and
  returns the refreshed access_token. Otherwise returns the existing
  access_token.

  ## Returns

  - `{:ok, access_token}` — the token string ready for a Bearer header.
  - `{:error, :not_found}` — no Google integration on the scope.
  - `{:error, :no_refresh_token}` — token expired but no refresh_token
    is stored to refresh with.
  - `{:error, reason}` — refresh attempt failed (network, provider).
  """
  @spec get_valid_token(Scope.t()) :: {:ok, String.t()} | {:error, term()}
  def get_valid_token(%Scope{} = scope) do
    with {:ok, integration} <- Integrations.get_integration(scope, :google) do
      maybe_refresh(scope, integration)
    end
  end

  defp maybe_refresh(scope, %Integration{} = integration) do
    if expired?(integration) do
      case Integrations.refresh_token(scope, :google) do
        {:ok, refreshed} -> {:ok, refreshed.access_token}
        {:error, _} = error -> error
      end
    else
      {:ok, integration.access_token}
    end
  end

  defp expired?(%Integration{expires_at: nil}), do: true

  defp expired?(%Integration{expires_at: %DateTime{} = expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end
end
