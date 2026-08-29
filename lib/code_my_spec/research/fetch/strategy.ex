defmodule CodeMySpec.Research.Fetch.Strategy do
  @moduledoc """
  How one family of URLs is read.

  Adapted from Omni Tools (Apache-2.0). A strategy gets two chances to be
  clever: it can change the URL that actually gets requested, and it can decide
  what the response means. GitHub only needs the first — a `blob` URL is a
  whole application wrapped around a file that is served plain one host over.
  Reddit needs both.
  """

  alias CodeMySpec.Research.Page

  @doc "Whether this strategy handles that URL. Strategies are tried in order."
  @callback matches?(URI.t()) :: boolean()

  @doc """
  The URL to actually request, or a refusal.

  Refusing here rather than in `extract/3` is the difference between not making
  a request and making one whose answer we already know to be useless — see
  `Reddit`, which is nothing but this.
  """
  @callback prepare(String.t(), URI.t()) :: String.t() | {:error, term()}

  @doc """
  What the response means.

  `requested` is the URL the caller asked for and `fetched` is the one that was
  actually requested. Both, because they differ whenever `prepare/2` did
  anything, and the difference is the strategy's whole visible effect — a
  result that only reported the requested URL would say a GitHub blob page was
  read when a raw file was.
  """
  @callback extract(Req.Response.t(), requested :: String.t(), fetched :: String.t()) ::
              {:ok, Page.t()} | {:error, term()}
end
