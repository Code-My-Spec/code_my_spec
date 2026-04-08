defmodule CodeMySpec.Embeddings.Serving do
  @moduledoc """
  Text embedding pipeline using Ortex (ONNX Runtime) with
  sentence-transformers/all-MiniLM-L6-v2.

  Produces 384-dimensional L2-normalized embeddings.
  Model file ships with the app at priv/models/all-MiniLM-L6-v2.onnx.
  Tokenizer downloaded from HuggingFace on first use, then cached.
  """

  use GenServer

  @model_path "priv/models/all-MiniLM-L6-v2.onnx"
  @tokenizer_id "sentence-transformers/all-MiniLM-L6-v2"
  @max_length 256

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Generate an embedding vector for the given text. Returns {:ok, [float]} or {:error, reason}."
  def embed(text) when is_binary(text) do
    GenServer.call(__MODULE__, {:embed, text}, 30_000)
  end

  @doc "Generate embeddings for a batch of texts. Returns {:ok, [[float]]} or {:error, reason}."
  def embed_batch(texts) when is_list(texts) do
    GenServer.call(__MODULE__, {:embed_batch, texts}, 60_000)
  end

  # -- GenServer callbacks --

  @impl true
  def init(_opts) do
    {:ok, model, tokenizer} = load_pipeline()
    {:ok, %{model: model, tokenizer: tokenizer}}
  end

  @impl true
  def handle_call({:embed, text}, _from, state) do
    {:reply, run_single(state, text), state}
  end

  def handle_call({:embed_batch, texts}, _from, state) do
    {:reply, run_batch(state, texts), state}
  end

  # -- Pipeline --

  defp load_pipeline do
    model_path = resolve_model_path()

    unless File.exists?(model_path) do
      {:error, "Model not found at #{model_path}"}
    else
      model = Ortex.load(model_path)
      {:ok, tokenizer} = Tokenizers.Tokenizer.from_pretrained(@tokenizer_id)
      {:ok, model, tokenizer}
    end
  end

  defp resolve_model_path do
    # In release: use Application.app_dir. In dev: use relative path.
    case :code.priv_dir(:code_my_spec) do
      {:error, _} -> @model_path
      priv_dir -> Path.join(priv_dir, "models/all-MiniLM-L6-v2.onnx")
    end
  end

  defp run_single(state, text) do
    case run_batch(state, [text]) do
      {:ok, [embedding]} -> {:ok, embedding}
      error -> error
    end
  end

  defp run_batch(%{model: model, tokenizer: tokenizer}, texts) do
    # 1. Tokenize
    {:ok, encodings} = Tokenizers.Tokenizer.encode_batch(tokenizer, texts)

    # 2. Truncate + pad to uniform length
    encodings = Enum.map(encodings, &Tokenizers.Encoding.truncate(&1, @max_length))

    max_len =
      encodings
      |> Enum.map(&(&1 |> Tokenizers.Encoding.get_ids() |> length()))
      |> Enum.max()

    encodings = Enum.map(encodings, &Tokenizers.Encoding.pad(&1, max_len))

    # 3. Build tensors (ONNX BERT expects int64)
    input_ids = encodings |> Enum.map(&Tokenizers.Encoding.get_ids/1) |> Nx.tensor(type: :s64)
    attention_mask = encodings |> Enum.map(&Tokenizers.Encoding.get_attention_mask/1)
    mask_tensor = Nx.tensor(attention_mask, type: :s64)
    token_type_ids = encodings |> Enum.map(&Tokenizers.Encoding.get_type_ids/1) |> Nx.tensor(type: :s64)

    # 4. Run inference
    {hidden_state} = Ortex.run(model, {input_ids, mask_tensor, token_type_ids})

    # 5. Transfer to default backend for math
    hidden_state = Nx.backend_transfer(hidden_state)

    # 6. Mean pooling (mask out padding tokens)
    mask_f32 = Nx.tensor(attention_mask, type: :f32)
    pooled = mean_pooling(hidden_state, mask_f32)

    # 7. L2 normalize
    normalized = l2_normalize(pooled)

    {:ok, Nx.to_list(normalized)}
  end

  defp mean_pooling(hidden_state, attention_mask) do
    mask_expanded = Nx.new_axis(attention_mask, -1)

    numerator =
      hidden_state
      |> Nx.multiply(mask_expanded)
      |> Nx.sum(axes: [1])

    denominator =
      mask_expanded
      |> Nx.sum(axes: [1])
      |> Nx.max(1.0e-9)

    Nx.divide(numerator, denominator)
  end

  defp l2_normalize(embeddings) do
    norms =
      embeddings
      |> Nx.pow(2)
      |> Nx.sum(axes: [-1], keep_axes: true)
      |> Nx.sqrt()
      |> Nx.max(1.0e-9)

    Nx.divide(embeddings, norms)
  end
end
