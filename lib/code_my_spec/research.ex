defmodule CodeMySpec.Research do
  @moduledoc """
  Looking something up on the open web: searching for it, and reading it.

  Agents working in this harness had no way to do either. Everything they could
  reach was inside the repository or inside our own database, so a question
  about a library's current API, a changed provider response, or an error
  nobody here has seen before had exactly one answer available: guess from
  training data. That is the gap this closes.

  ## Provenance

  Adapted from [Omni Tools](https://github.com/aaronrussell/omni_tools) by
  Aaron Russell, Apache-2.0. Theirs are the provider request and response
  shapes for Brave, Serper and Tavily, and the idea of layering the fetch
  behind per-site strategies with GitHub and Reddit as the two that earn one.

  Deliberate departures, each with its reason stated where it lives:

    * The search provider is inferred from whichever key is set rather than
      named at construction (`Search`).
    * HTML is converted here with Floki rather than by `Html2Markdown`, and
      page furniture is stripped before conversion (`Html`).
    * Truncation is reported in the result rather than applied silently
      (`Page.truncate/2`).

  ## Configuration

      config :code_my_spec, CodeMySpec.Research,
        tavily_api_key: ...,      # or brave_api_key / serper_api_key
        search_provider: :tavily, # optional; inferred from the keys otherwise
        max_output: 100_000,
        timeout: to_timeout(second: 15)

  Fetching needs no configuration. Searching needs a key for one of the three
  providers; with none set, `search/2` refuses in a way that names them.
  """

  alias CodeMySpec.Research.{Fetch, Page, Result, Search}

  @doc """
  Searches the web.

  ## Options

    * `:num_results` — how many hits to return. Defaults to 5.
    * `:recency` — `:day`, `:week`, `:month` or `:year`. Every provider
      expresses this differently and each one translates it.
  """
  @spec search(String.t(), keyword()) :: {:ok, [Result.t()]} | {:error, term()}
  defdelegate search(query, opts \\ []), to: Search

  @doc """
  Reads one URL. See `Fetch.fetch/2` for options.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, Page.t()} | {:error, term()}
  defdelegate fetch(url, opts \\ []), to: Fetch

  @doc "Whether a search provider is configured, and which."
  @spec search_provider() :: {:ok, module(), String.t()} | {:error, term()}
  defdelegate search_provider(), to: Search, as: :provider
end
