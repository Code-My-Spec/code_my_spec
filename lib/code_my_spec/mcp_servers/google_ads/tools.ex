# Google Ads MCP tools — one Anubis component module per tool, modeled on
# the GA4/GSC tool modules. Thin wrappers over `CodeMySpec.Google.Ads`,
# rendered via `CodeMySpec.McpServers.GoogleTools`.
#
# Read tools run automatically. Write (mutate) tools execute the change
# directly; the human-in-the-loop gate is Claude Code's built-in per-call
# approval prompt, not a server-side flag — so there is no `destructive`
# check here (cf. the GSC tools).

defmodule CodeMySpec.McpServers.GoogleAds.Tools do
  @moduledoc false

  # Builds the keyword opts for the client read/write functions from the tool
  # params, dropping nil values.

  @spec read_opts(map()) :: keyword()
  def read_opts(params) do
    [:date_range, :limit, :login_customer_id]
    |> collect(params)
  end

  @spec write_opts(map()) :: keyword()
  def write_opts(params) do
    [:login_customer_id]
    |> collect(params)
  end

  defp collect(keys, params) do
    Enum.reduce(keys, [], fn key, acc ->
      case Map.get(params, key) do
        nil -> acc
        value -> [{key, value} | acc]
      end
    end)
  end
end
