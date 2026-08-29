defmodule CodeMySpec.Research.Search.Tavily do
  @moduledoc """
  Tavily — a search API built for agents. Shape adapted from Omni Tools
  (Apache-2.0).

  Its `content` field is an extract of the page rather than a SERP snippet, so
  the snippets here are longer and more useful than the other two providers'
  and sometimes answer the question without a fetch.
  """

  @behaviour CodeMySpec.Research.Search.Provider

  alias CodeMySpec.Research.{Http, Result, Search}

  @endpoint "https://api.tavily.com/search"
  @recency [:day, :week, :month, :year]

  @impl true
  def key_name, do: "TAVILY_API_KEY"

  @impl true
  def search(query, opts) do
    body =
      %{query: query, max_results: Keyword.get(opts, :num_results, 5)}
      |> put_recency(Keyword.get(opts, :recency))

    [
      method: :post,
      url: @endpoint,
      json: body,
      auth: {:bearer, Keyword.fetch!(opts, :api_key)}
    ]
    |> Http.new()
    |> Req.request()
    |> Search.handle(&results/1)
  end

  defp put_recency(body, recency) when recency in @recency,
    do: Map.put(body, :time_range, to_string(recency))

  defp put_recency(body, _recency), do: body

  defp results(%{"results" => results}) when is_list(results) do
    Enum.map(results, fn result ->
      %Result{
        title: result["title"],
        url: result["url"],
        snippet: result["content"] || ""
      }
    end)
  end

  defp results(_body), do: []
end
