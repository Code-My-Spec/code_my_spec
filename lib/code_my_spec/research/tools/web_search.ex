defmodule CodeMySpec.Research.Tools.WebSearch do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Research
  alias CodeMySpec.Research.Tools

  @max_results 20

  @impl true
  def name, do: "web_search"

  @impl true
  def description do
    """
    Search the web.

    Use this when the answer is not in the repository and not in the knowledge
    library: a library's current API, a provider's error codes, whether a
    workaround is still needed. Follow up with `web_fetch` on the results worth
    reading — the snippets are a way to choose a page, not a substitute for one.
    """
  end

  @impl true
  def params do
    %{
      query: {:required, {:meta, :string, [description: "What to search for"]}},
      num_results:
        {:meta, :integer,
         [description: "How many results to return. Default 5, maximum #{@max_results}"]},
      recency:
        {:meta, :string,
         [
           description:
             "Restrict to results from the last 'day', 'week', 'month' or 'year'. Omit for no restriction"
         ]}
    }
  end

  @impl true
  def call(%{query: query} = params, context) do
    with {:ok, recency} <- recency(params),
         {:ok, _scope} <- Tools.scoped(context) do
      case Research.search(query, num_results: num_results(params), recency: recency) do
        {:ok, []} -> {:ok, "No results for #{inspect(query)}."}
        {:ok, results} -> {:ok, format(query, results)}
        {:error, reason} -> {:error, message(reason)}
      end
    end
  end

  defp num_results(%{num_results: n}) when is_integer(n) and n > 0, do: min(n, @max_results)
  defp num_results(_params), do: 5

  defp recency(%{recency: nil}), do: {:ok, nil}
  defp recency(%{recency: "day"}), do: {:ok, :day}
  defp recency(%{recency: "week"}), do: {:ok, :week}
  defp recency(%{recency: "month"}), do: {:ok, :month}
  defp recency(%{recency: "year"}), do: {:ok, :year}

  defp recency(%{recency: value}),
    do: {:error, "Invalid recency #{inspect(value)}. Use day, week, month or year."}

  defp recency(_params), do: {:ok, nil}

  defp format(query, results) do
    body =
      results
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {result, index} ->
        ["#{index}. #{result.title}", "   #{result.url}", snippet(result.snippet)]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")
      end)

    "#{length(results)} results for #{inspect(query)}\n\n#{body}"
  end

  defp snippet(""), do: ""
  defp snippet(nil), do: ""
  defp snippet(text), do: "   #{String.replace(text, "\n", " ")}"

  # Names the variables: "no search provider" is not something the agent can
  # act on, and the operator reading its output can.
  defp message({:no_provider, key_names}) do
    """
    No search provider is configured. Set one of these and restart the server:

    #{Enum.map_join(key_names, "\n", &("  " <> &1))}

    Tavily (tavily.com) is the one to reach for first — it returns page
    extracts rather than SERP snippets, which is often the whole answer.
    """
  end

  defp message({:no_key, key_name}),
    do: "A search provider is configured but #{key_name} is not set."

  defp message({:unknown_provider, name, known}),
    do:
      "Unknown search provider #{inspect(name)}. Known: #{Enum.map_join(known, ", ", &to_string/1)}."

  defp message({:status, 401, detail}),
    do: "The search provider rejected the key (401). #{detail}"

  defp message({:status, 429, detail}),
    do: "The search provider is rate limiting or out of quota (429). #{detail}"

  defp message({:status, status, detail}), do: "The search provider answered #{status}. #{detail}"
  defp message(reason) when is_binary(reason), do: reason
  defp message(reason), do: inspect(reason)
end
