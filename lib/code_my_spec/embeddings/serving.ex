defmodule CodeMySpec.Embeddings.Serving do
  @moduledoc """
  Embedding serving behaviour and dispatch.

  Delegates to the configured implementation module — `OrtexServing`
  (Ortex/ONNX Runtime) everywhere embeddings run, CLI or server.

  One shared model, one queue, not two instances: every request carries a
  priority, `:search` or `:bulk`, and the implementation is the thing that
  has to honor it (John, embeddings rework step 2: a query embed must not
  wait behind a package's worth of chunks). Search always calls with
  `:search`; the hex-doc reconciler and the FLAME pool's bulk work
  (step 3) always call with `:bulk`.
  """

  @callback start_link(keyword()) :: GenServer.on_start()
  @callback embed(String.t(), :search | :bulk) :: {:ok, [float()]} | {:error, term()}
  @callback embed_batch([String.t()], :search | :bulk) :: {:ok, [[float()]]} | {:error, term()}
  @callback model_name() :: String.t()

  def child_spec(opts) do
    impl().child_spec(opts)
  end

  @doc """
  The model name every row this serving produces should be stamped with.

  `doc_embeddings.model`/`doc_packages.model` exist so a serving swap
  becomes a re-embed rather than silently mixing vector spaces — this is
  where that string comes from, so it is asked once rather than hardcoded
  at every call site.
  """
  @spec model_name() :: String.t()
  def model_name, do: impl().model_name()

  def start_link(opts) do
    impl().start_link(opts)
  end

  def embed(text, priority) when is_binary(text) and priority in [:search, :bulk] do
    impl().embed(text, priority)
  end

  def embed_batch(texts, priority) when is_list(texts) and priority in [:search, :bulk] do
    impl().embed_batch(texts, priority)
  end

  defp impl do
    Application.get_env(:code_my_spec, :embedding_serving, CodeMySpec.Embeddings.OrtexServing)
  end
end
