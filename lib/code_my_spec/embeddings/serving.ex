defmodule CodeMySpec.Embeddings.Serving do
  @moduledoc """
  Embedding serving behaviour and dispatch.

  Delegates to the configured implementation module. In CLI environments
  this is `CodeMySpec.Embeddings.OrtexServing` (Ortex/ONNX Runtime).
  """

  @callback start_link(keyword()) :: GenServer.on_start()
  @callback embed(String.t()) :: {:ok, [float()]} | {:error, term()}
  @callback embed_batch([String.t()]) :: {:ok, [[float()]]} | {:error, term()}

  def child_spec(opts) do
    impl().child_spec(opts)
  end

  def start_link(opts) do
    impl().start_link(opts)
  end

  def embed(text) when is_binary(text) do
    impl().embed(text)
  end

  def embed_batch(texts) when is_list(texts) do
    impl().embed_batch(texts)
  end

  defp impl do
    Application.get_env(:code_my_spec, :embedding_serving, CodeMySpec.Embeddings.OrtexServing)
  end
end
