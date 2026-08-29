defmodule CodeMySpec.Research.Search.Provider do
  @moduledoc """
  One web-search back end.

  Adapted from Omni Tools (Apache-2.0), whose `WebSearch.Provider` behaviour
  this is. The indirection earns its keep because nobody holds a key for the
  same search API as anybody else: the tool has to work against whichever one
  the operator happens to have.
  """

  alias CodeMySpec.Research.Result

  @type opts :: [num_results: pos_integer(), recency: Result.recency(), api_key: String.t()]

  @callback search(query :: String.t(), opts()) :: {:ok, [Result.t()]} | {:error, term()}

  @doc "The env var this provider's key comes from. Named in refusals."
  @callback key_name() :: String.t()
end
