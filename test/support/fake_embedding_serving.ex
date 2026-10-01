defmodule CodeMySpecTest.FakeEmbeddingServing do
  @moduledoc """
  A `CodeMySpec.Embeddings.Serving` that never loads Ortex.

  Returns the same fixed vector for every input — tests that configure this
  care about which rows a query's scope includes, not fine-grained ranking,
  so every embedding tying is fine.
  """

  @behaviour CodeMySpec.Embeddings.Serving

  @vector List.duplicate(0.1, 384)

  @impl true
  def start_link(_opts), do: :ignore

  @impl true
  def embed(_text), do: {:ok, @vector}

  @impl true
  def embed_batch(texts), do: {:ok, Enum.map(texts, fn _ -> @vector end)}
end
