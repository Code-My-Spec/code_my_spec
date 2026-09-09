defmodule CodeMySpec.Google do
  @moduledoc """
  The Google APIs this app talks to on a user's behalf, and the one thing they
  share: a token that is valid right now.

  Four clients live under here, and they are not variations on one API — they
  are separate Google products with separate hosts, separate auth scopes and
  separate shapes:

  - `Google.Ads` — Google Ads (campaigns, ad groups, keywords, bids)
  - `Google.Gsc` — Search Console (sites, search analytics, sitemaps, URL inspection)
  - `Google.Ga4` — GA4 Data API (reports, funnels, realtime)
  - `Google.Analytics` — GA Admin API (accounts and properties)

  ## Why this delegates one function and not sixty-six

  Every function on those clients corresponds 1:1 to an MCP tool, takes a
  bearer token as its first argument so `ReqCassette` can drive it, and is
  called from exactly one place. Re-exporting all of them here would copy the
  entire surface to gain nothing: no caller would be shorter, and
  `Google.get_campaign_performance/2` reads worse than `Google.Ads` does, because
  a reader of the first cannot tell which product answered.

  What every one of them does share is the token. The tool layer resolves it,
  then calls the client — so the token is the cross-cutting entry point and the
  only thing that belongs at this level. That is `StaticAnalysis`'s arrangement
  too: a small facade over what callers cross the boundary for, with the
  internals left addressable for what they do alone.

  The product clients are therefore public and expected to be named directly.
  What is *not* expected is reaching for `Google.Auth`, which is now this.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Integrations, CodeMySpec.Users],
    exports: :all

  alias CodeMySpec.Google.Auth

  @doc """
  A Google access token that is valid now, refreshing first if needed.

  Google's tokens expire in an hour, which is why refresh was built here before
  anywhere else. The logic itself lives in `Integrations.fetch_access_token/2`
  now — shared with every other provider, and fixed there for the two bugs a
  Google-only version had: comparing against the exact expiry, so a token with
  two seconds left passed and then failed mid-request, and not serialising, so
  concurrent callers both refreshed.

  - `{:ok, access_token}` — ready for a Bearer header
  - `{:error, :not_found}` — no Google integration on the scope
  - `{:error, :reauthorize_required}` — expired with nothing to refresh with
  - `{:error, reason}` — the provider refused the refresh
  """
  defdelegate get_valid_token(scope), to: Auth
end
