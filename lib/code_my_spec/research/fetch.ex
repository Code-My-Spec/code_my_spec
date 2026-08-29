defmodule CodeMySpec.Research.Fetch do
  @moduledoc """
  Reads one URL. Adapted from Omni Tools (Apache-2.0).

  The strategy list is tried in order and `Default` matches everything, so the
  list always terminates.

  Two of the three strategies exist because the generic reading of those URLs
  is wrong rather than merely worse: a GitHub blob page is an application
  wrapped around a file, and a Reddit thread is a login wall that converts to
  Markdown perfectly well and says nothing.
  """

  alias CodeMySpec.Research.Fetch.{Default, GitHub, Reddit}
  alias CodeMySpec.Research.{Http, Page}

  @strategies [GitHub, Reddit, Default]

  @default_max_output 100_000

  # Reddit refuses a request that does not identify itself, and several CDNs
  # answer a blank agent with a challenge page. Naming the tool is also the
  # honest thing to do — the operator of a site we read should be able to tell
  # who read it.
  @user_agent "CodeMySpec/1.0 (+https://codemyspec.com; agent research tool)"

  @type error ::
          {:unsupported_scheme, String.t()}
          | {:status, integer(), String.t()}
          | :invalid_url
          | :reddit_requires_oauth
          | term()

  @doc """
  Fetches `url` and returns what was there.

  ## Options

    * `:max_output` — bytes of content to keep, or `:infinity`. Defaults to
      100_000, which is roughly the point past which a page costs more context
      than it is worth.
    * `:timeout` — receive timeout in milliseconds.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, Page.t()} | {:error, error()}
  def fetch(url, opts \\ []) when is_binary(url) do
    with {:ok, uri} <- parse(url),
         strategy = strategy(uri),
         {:ok, fetched} <- prepare(strategy, url, uri),
         {:ok, response} <- request(fetched, opts),
         :ok <- ok_status(response),
         {:ok, page} <- strategy.extract(response, url, fetched) do
      {:ok, Page.truncate(page, Keyword.get(opts, :max_output, max_output()))}
    end
  end

  @doc "The strategy that would read that URL. Exposed so it can be asserted on."
  @spec strategy(URI.t()) :: module()
  def strategy(%URI{} = uri), do: Enum.find(@strategies, Default, & &1.matches?(uri))

  defp prepare(strategy, url, uri) do
    case strategy.prepare(url, uri) do
      {:error, _reason} = error -> error
      fetched when is_binary(fetched) -> {:ok, fetched}
    end
  end

  defp parse(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme} = uri} when scheme in ["http", "https"] ->
        {:ok, uri}

      # Named rather than folded into `:invalid_url` because `file:` and
      # `data:` are the shapes that turn a fetch tool into a way to read the
      # server's disk, and a refusal that says which scheme is the one that
      # tells the caller to stop trying.
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) ->
        {:error, {:unsupported_scheme, scheme}}

      _other ->
        {:error, :invalid_url}
    end
  end

  defp request(url, opts) do
    [method: :get, url: url, headers: [{"user-agent", @user_agent}]]
    |> Keyword.merge(Keyword.take(opts, [:timeout]))
    |> Http.new()
    |> Req.request()
    |> case do
      {:ok, response} -> {:ok, response}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  defp ok_status(%Req.Response{status: status}) when status in 200..299, do: :ok

  defp ok_status(%Req.Response{status: status, body: body}),
    do: {:error, {:status, status, summary(body)}}

  defp summary(body) when is_binary(body), do: body |> String.slice(0, 200) |> String.trim()
  defp summary(body), do: body |> inspect() |> String.slice(0, 200)

  defp max_output, do: Http.config(:max_output, @default_max_output)
end
