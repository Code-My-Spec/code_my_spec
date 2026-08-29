defmodule CodeMySpec.Research.Search.Brave do
  @moduledoc """
  Brave Search. Request shape adapted from Omni Tools (Apache-2.0).

  Results live at `web.results`; recency is a `freshness` code rather than a
  date range.
  """

  @behaviour CodeMySpec.Research.Search.Provider

  alias CodeMySpec.Research.{Http, Result, Search}

  @endpoint "https://api.search.brave.com/res/v1/web/search"
  @freshness %{day: "pd", week: "pw", month: "pm", year: "py"}

  @impl true
  def key_name, do: "BRAVE_API_KEY"

  @impl true
  def search(query, opts) do
    params =
      [q: query, count: Keyword.get(opts, :num_results, 5)]
      |> put_freshness(Keyword.get(opts, :recency))

    [
      method: :get,
      url: @endpoint,
      params: params,
      headers: [
        {"x-subscription-token", Keyword.fetch!(opts, :api_key)},
        {"accept", "application/json"}
      ]
    ]
    |> Http.new()
    |> Req.request()
    |> Search.handle(&results/1)
  end

  defp put_freshness(params, nil), do: params

  defp put_freshness(params, recency) do
    case Map.fetch(@freshness, recency) do
      {:ok, code} -> Keyword.put(params, :freshness, code)
      :error -> params
    end
  end

  defp results(%{"web" => %{"results" => results}}) when is_list(results) do
    Enum.map(results, fn result ->
      %Result{
        title: result["title"],
        url: result["url"],
        snippet: result["description"] || ""
      }
    end)
  end

  # A query Brave has nothing for answers 200 with no `web` key at all, which
  # is no results rather than a malformed response.
  defp results(_body), do: []
end
