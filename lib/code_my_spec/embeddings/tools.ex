defmodule CodeMySpec.Embeddings.Tools do
  @moduledoc "The embedding tools agents call, independent of the MCP surface."

  def all, do: [__MODULE__.SemanticSearch]
end
