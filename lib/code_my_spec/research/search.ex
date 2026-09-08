defmodule CodeMySpec.Research.Search do
  @moduledoc """
  Picks a search provider and normalises what it says.

  Adapted from Omni Tools (Apache-2.0). The one deliberate difference is how a
  provider gets chosen: Omni names one at construction, this infers it from
  whichever key is actually set. The tool is registered on a server that a
  dozen agents share, so it has to be right without anybody having configured
  it for their session — and the failure mode of "configured for a provider
  whose key is missing" is a refusal an agent cannot act on.
  """

  alias CodeMySpec.Research.Http
  alias CodeMySpec.Research.Search.{Brave, Serper, Tavily}

  # Ordered by how well each serves an agent reading the results, so an
  # operator holding two keys gets the better one without choosing.
  @providers [
    {:tavily, Tavily, :tavily_api_key},
    {:brave, Brave, :brave_api_key},
    {:serper, Serper, :serper_api_key}
  ]

  @type error ::
          {:no_provider, [String.t()]}
          | {:no_key, String.t()}
          | {:status, integer(), String.t()}
          | term()

  @doc """
  Searches with the configured provider.

  Returns `{:error, {:no_provider, key_names}}` when none is configured — the
  caller is expected to turn that into a message naming the variables, because
  "search is unavailable" is not something an agent can do anything about.
  """
  @spec search(String.t(), keyword()) ::
          {:ok, [CodeMySpec.Research.Result.t()]} | {:error, error()}
  def search(query, opts \\ []) do
    with {:ok, module, api_key} <- provider() do
      module.search(query, Keyword.put(opts, :api_key, api_key))
    end
  end

  # credo:disable-for-next-line ExSlop.Check.Readability.NarratorDoc
  @doc "The provider that would be used, its module and key. Also drives refusals."
  @spec provider() :: {:ok, module(), String.t()} | {:error, error()}
  def provider do
    config = Http.config()

    case Keyword.get(config, :search_provider) do
      nil -> first_configured(config)
      name -> named(config, name)
    end
  end

  defp first_configured(config) do
    Enum.find_value(@providers, {:error, {:no_provider, key_names()}}, fn {_name, module, key} ->
      case Keyword.get(config, key) do
        blank when blank in [nil, ""] -> nil
        api_key -> {:ok, module, api_key}
      end
    end)
  end

  defp named(config, name) do
    case List.keyfind(@providers, name, 0) do
      nil ->
        {:error, {:unknown_provider, name, Enum.map(@providers, &elem(&1, 0))}}

      {_name, module, key} ->
        case Keyword.get(config, key) do
          blank when blank in [nil, ""] -> {:error, {:no_key, module.key_name()}}
          api_key -> {:ok, module, api_key}
        end
    end
  end

  @doc "The env var each provider reads its key from."
  @spec key_names() :: [String.t()]
  def key_names, do: Enum.map(@providers, fn {_name, module, _key} -> module.key_name() end)

  @doc """
  Turns a provider's `Req` result into results or a usable error.

  Shared because all three fail the same way and say so differently: a bad key
  is a 401 with the reason buried under a different JSON path per provider, and
  a caller that only reports the status cannot tell "key expired" from "quota
  spent" — which is the distinction the operator needs.
  """
  @spec handle({:ok, Req.Response.t()} | {:error, Exception.t()}, (map() -> [struct()])) ::
          {:ok, [struct()]} | {:error, error()}
  def handle({:ok, %{status: 200, body: body}}, parse) when is_map(body), do: {:ok, parse.(body)}

  def handle({:ok, %{status: 200, body: body}}, parse) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, parse.(decoded)}
      {:error, _} -> {:error, {:unparseable_body, String.slice(body, 0, 200)}}
    end
  end

  def handle({:ok, %{status: status, body: body}}, _parse),
    do: {:error, {:status, status, detail(body)}}

  def handle({:error, exception}, _parse), do: {:error, Exception.message(exception)}

  defp detail(%{"error" => %{"detail" => detail}}) when is_binary(detail), do: detail
  defp detail(%{"error" => error}) when is_binary(error), do: error
  defp detail(%{"message" => message}) when is_binary(message), do: message
  defp detail(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp detail(body), do: body |> inspect() |> String.slice(0, 200)
end
