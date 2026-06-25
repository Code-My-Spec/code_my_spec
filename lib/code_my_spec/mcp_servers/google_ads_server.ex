defmodule CodeMySpec.McpServers.GoogleAdsServer do
  @moduledoc """
  MCP server exposing Google Ads API tools, modeled on `Ga4Server` /
  `GscServer`.

  Scope and Google OAuth token are resolved per call from the working dir
  (see `CodeMySpec.McpServers.GoogleTools`). Read tools run automatically;
  write (mutate) tools execute the change directly and rely on Claude Code's
  built-in per-call approval prompt as the human-in-the-loop gate — there is
  no server-side destructive flag.

  ## Restart required after tool changes

  Adding or removing a `component(...)` below requires a full `cms server`
  restart to take effect — the running BEAM binds its tool registry at boot.
  """

  use Anubis.Server,
    name: "codemyspec-google-ads",
    version: "1.0.0",
    capabilities: [:tools]

  alias CodeMySpec.McpServers.GoogleAds.Tools

  # Reads — run automatically
  component(Tools.ListAccessibleAccounts)
  component(Tools.GetAccountOverview)
  component(Tools.GetCampaignPerformance)
  component(Tools.GetAdGroupPerformance)
  component(Tools.GetKeywordPerformance)
  component(Tools.GetSearchTermsReport)
  component(Tools.GetAdPerformance)
  component(Tools.GetRecommendations)

  # Writes — mutating, gated by Claude Code's per-call approval
  component(Tools.UpdateCampaignBudget)
  component(Tools.UpdateBid)
  component(Tools.UpdateCampaignStatus)
  component(Tools.AddKeywords)
  component(Tools.AddNegativeKeywords)
  component(Tools.CreateAd)
end
