defmodule CodeMySpec.Research.Result do
  @moduledoc "One search hit, in the shape every provider is normalised into."

  @enforce_keys [:title, :url]
  defstruct [:title, :url, snippet: ""]

  @type t :: %__MODULE__{title: String.t(), url: String.t(), snippet: String.t()}
  @type recency :: :day | :week | :month | :year | nil
end
