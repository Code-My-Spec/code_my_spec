defmodule CodeMySpec.McpServers.Gsc.Tools.ManageSitemaps do
  @moduledoc """
  All-in-one sitemap management: list, details, submit, or delete. Delegates
  to the dedicated tools.
  """
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  @valid_actions ~w(list details submit delete)

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :action, :string, required: true, doc: "list, details, submit, or delete"
    field :sitemap_url, :string, doc: "Required for details, submit, delete"
    field :sitemap_index, :string, doc: "Optional sitemap index URL (list action only)"
  end

  @impl true
  def execute(params, frame) do
    action = params.action |> String.downcase() |> String.trim()

    cond do
      action not in @valid_actions ->
        {:reply, GoogleTools.text("Invalid action: #{action}. Use one of: #{Enum.join(@valid_actions, ", ")}"), frame}

      action in ~w(details submit delete) and is_nil(params[:sitemap_url]) ->
        {:reply, GoogleTools.text("The #{action} action requires a sitemap_url parameter."), frame}

      true ->
        dispatch(action, params, frame)
    end
  end

  defp dispatch(action, params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- run(action, token, params) do
      {:reply, GoogleTools.ok("Sitemap #{action} for #{params.site_url}.", data), frame}
    else
      {:reply, _resp, _frame} = reply -> reply
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end

  defp run("list", token, params),
    do: Gsc.list_sitemaps_enhanced(token, params.site_url, params[:sitemap_index])

  defp run("details", token, params),
    do: Gsc.get_sitemap_details(token, params.site_url, params.sitemap_url)

  defp run("submit", token, params),
    do: Gsc.submit_sitemap(token, params.site_url, params.sitemap_url)

  defp run("delete", token, params) do
    if GoogleTools.destructive_allowed?() do
      Gsc.delete_sitemap(token, params.site_url, params.sitemap_url)
    else
      {:error, :destructive_disabled}
    end
  end
end
