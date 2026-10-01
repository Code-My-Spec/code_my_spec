defmodule CodeMySpec.Embeddings.OrtexServing do
  @moduledoc """
  Text embedding pipeline using Ortex (ONNX Runtime) with
  sentence-transformers/all-MiniLM-L6-v2.

  Produces 384-dimensional L2-normalized embeddings.
  Model and tokenizer both ship with the app under priv/models/ — nothing is
  fetched at runtime, so the pipeline works fully offline regardless of the
  host's TLS/CA configuration.

  ## One model, one queue, priority inside it

  Embeddings rework step 2 (577de9bb): the server shares this one GenServer
  between a search's single query embed and the hex-doc reconciler's/FLAME
  pool's bulk batches (step 3). A plain GenServer mailbox is FIFO, which
  would leave a search waiting behind whichever package happened to be
  queued first — exactly the 30s-timeout risk flagged reviewing step 2.

  So a call is a request with a priority, not a direct `GenServer.call` that
  runs inline: `handle_call` enqueues onto one of two internal queues
  (`:search` or `:bulk`) and replies later via `GenServer.reply/2`, while the
  actual Ortex run happens in a linked worker process fed one job at a time.
  Keeping inference off the GenServer's own call stack is what lets new
  requests keep arriving — and get correctly prioritised against whatever is
  still waiting — while a worker is busy. The next job always comes off the
  search queue first; a job already running cannot be pre-empted, so a
  worst-case search still waits for one in-flight batch, never for a
  backlog. The cap on bulk batch size (step 3) is what bounds that wait.
  """

  @behaviour CodeMySpec.Embeddings.Serving

  use GenServer

  alias Tokenizers.Encoding

  @model_path "priv/models/all-MiniLM-L6-v2.onnx"
  @tokenizer_path "priv/models/all-MiniLM-L6-v2.tokenizer.json"
  @max_length 256

  @impl CodeMySpec.Embeddings.Serving
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl CodeMySpec.Embeddings.Serving
  def embed(text, priority) when is_binary(text) and priority in [:search, :bulk] do
    case GenServer.call(__MODULE__, {:enqueue, priority, {:single, text}}, 30_000) do
      {:ok, [embedding]} -> {:ok, embedding}
      error -> error
    end
  end

  @impl CodeMySpec.Embeddings.Serving
  def embed_batch(texts, priority) when is_list(texts) and priority in [:search, :bulk] do
    GenServer.call(__MODULE__, {:enqueue, priority, {:batch, texts}}, 60_000)
  end

  # -- GenServer callbacks --

  @impl GenServer
  def init(opts) do
    run_fn = Keyword.get(opts, :run_fn, &run_pipeline/2)

    state = %{
      pipeline: nil,
      run_fn: run_fn,
      search: :queue.new(),
      bulk: :queue.new(),
      worker: nil
    }

    if run_fn == (&run_pipeline/2) do
      case load_pipeline() do
        {:ok, model, tokenizer} -> {:ok, %{state | pipeline: {model, tokenizer}}}
        {:error, reason} -> {:stop, reason}
      end
    else
      # Test-only seam: a run_fn that doesn't touch Ortex at all needs no
      # pipeline loaded, which is what keeps the priority queue's own tests
      # from paying for a 90MB model load just to prove dispatch order.
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_call({:enqueue, priority, job}, from, state) do
    state = enqueue(state, priority, from, job)
    state = if state.worker, do: state, else: dispatch_next(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:job_done, from, result}, state) do
    GenServer.reply(from, result)
    {:noreply, dispatch_next(%{state | worker: nil})}
  end

  # -- Queue + dispatch --

  defp enqueue(state, :search, from, job), do: %{state | search: :queue.in({from, job}, state.search)}
  defp enqueue(state, :bulk, from, job), do: %{state | bulk: :queue.in({from, job}, state.bulk)}

  # Search first, always — a job already handed to the worker runs to
  # completion either way, so this only decides what goes *next*.
  defp pop_next(%{search: search, bulk: bulk} = state) do
    case :queue.out(search) do
      {{:value, item}, rest} -> {item, %{state | search: rest}}
      {:empty, _} ->
        case :queue.out(bulk) do
          {{:value, item}, rest} -> {item, %{state | bulk: rest}}
          {:empty, _} -> {nil, state}
        end
    end
  end

  defp dispatch_next(state) do
    case pop_next(state) do
      {nil, state} ->
        %{state | worker: nil}

      {{from, job}, state} ->
        parent = self()
        run_fn = state.run_fn
        pipeline = state.pipeline

        {:ok, pid} =
          Task.start_link(fn ->
            result = run_fn.(pipeline, job)
            send(parent, {:job_done, from, result})
          end)

        %{state | worker: pid}
    end
  end

  # -- Pipeline --

  defp load_pipeline do
    model_path = resolve_priv_path(@model_path)
    tokenizer_path = resolve_priv_path(@tokenizer_path)

    cond do
      not File.exists?(model_path) ->
        {:error, "Model not found at #{model_path}"}

      not File.exists?(tokenizer_path) ->
        {:error, "Tokenizer not found at #{tokenizer_path}"}

      true ->
        model = Ortex.load(model_path)
        {:ok, tokenizer} = Tokenizers.Tokenizer.from_file(tokenizer_path)
        {:ok, model, tokenizer}
    end
  end

  defp resolve_priv_path(relative_path) do
    case :code.priv_dir(:code_my_spec) do
      {:error, _} -> relative_path
      priv_dir -> Path.join(priv_dir, Path.relative_to(relative_path, "priv"))
    end
  end

  defp run_pipeline(pipeline, {:single, text}), do: run_pipeline(pipeline, {:batch, [text]})

  defp run_pipeline({model, tokenizer}, {:batch, texts}) do
    {:ok, encodings} = Tokenizers.Tokenizer.encode_batch(tokenizer, texts)

    encodings = Enum.map(encodings, &Encoding.truncate(&1, @max_length))

    max_len =
      encodings
      |> Enum.map(&(&1 |> Encoding.get_ids() |> length()))
      |> Enum.max()

    encodings = Enum.map(encodings, &Encoding.pad(&1, max_len))

    input_ids = encodings |> Enum.map(&Encoding.get_ids/1) |> Nx.tensor(type: :s64)
    attention_mask = encodings |> Enum.map(&Encoding.get_attention_mask/1)
    mask_tensor = Nx.tensor(attention_mask, type: :s64)
    token_type_ids = encodings |> Enum.map(&Encoding.get_type_ids/1) |> Nx.tensor(type: :s64)

    {hidden_state} = Ortex.run(model, {input_ids, mask_tensor, token_type_ids})

    hidden_state = Nx.backend_transfer(hidden_state)

    mask_f32 = Nx.tensor(attention_mask, type: :f32)
    pooled = mean_pooling(hidden_state, mask_f32)

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
