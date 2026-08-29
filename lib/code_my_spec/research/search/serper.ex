defmodule CodeMySpec.Research.Search.Serper do
  @moduledoc """
  Serper — Google results over an API. Shape adapted from Omni Tools
  (Apache-2.0).

  Organic hits only. Serper also returns answer boxes and knowledge panels;
  those are Google's summary of the page rather than the page, and an agent
  that is about to fetch the page anyway is better served by the list.
  """

  @behaviour CodeMySpec.Research.Search.Provider

  alias CodeMySpec.Research.{Http, Result, Search}

  @endpoint "https://google.serper.dev/search"
  @recency %{day: "qdr:d", week: "qdr:w", month: "qdr:m", year: "qdr:y"}

  @impl true
  def key_name, do: "SERPER_API_KEY"

  @impl true
  def search(query, opts) do
    body =
      %{q: query, num: Keyword.get(opts, :num_results, 5)}
      |> put_recency(Keyword.get(opts, :recency))

    [
      method: :post,
      url: @endpoint,
      json: body,
      headers: [{"x-api-key", Keyword.fetch!(opts, :api_key)}]
    ]
    |> Http.new()
    |> Req.request()
    |> Search.handle(&results/1)
  end

  defp put_recency(body, nil), do: body

  defp put_recency(body, recency) do
    case Map.fetch(@recency, recency) do
      {:ok, tbs} -> Map.put(body, :tbs, tbs)
      :error -> body
    end
  end

  defp results(%{"organic" => results}) when is_list(results) do
    Enum.map(results, fn result ->
      %Result{
        title: result["title"],
        url: result["link"],
        snippet: result["snippet"] || ""
      }
    end)
  end

  defp results(_body), do: []
end
