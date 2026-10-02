defmodule CodeMySpecTest.RecordingEmbeddingServing do
  @moduledoc """
  A `CodeMySpec.Embeddings.Serving` that reports every batch it embeds to the
  test process that installed it, and can be told to fail. Same fixed vector
  as `FakeEmbeddingServing`: what these tests ask is which content was
  embedded and which rows search may return, not ranking.
  """

  @behaviour CodeMySpec.Embeddings.Serving

  @vector List.duplicate(0.1, 384)

  @doc "Report batches to `pid` from now on."
  def listen(pid), do: :persistent_term.put({__MODULE__, :pid}, pid)

  @doc "Fail every batch while `fail?` is true."
  def fail(fail?), do: :persistent_term.put({__MODULE__, :fail}, fail?)

  @doc "Answer `model_name/0` with `name`, as a different model would."
  def model(name), do: :persistent_term.put({__MODULE__, :model}, name)

  @doc "Stop reporting, stop failing, back to the default model."
  def reset do
    :persistent_term.erase({__MODULE__, :pid})
    :persistent_term.erase({__MODULE__, :fail})
    :persistent_term.erase({__MODULE__, :model})
  end

  @impl true
  def start_link(_opts), do: :ignore

  @impl true
  def embed(_text, _priority), do: {:ok, @vector}

  @impl true
  def embed_batch(texts, priority) do
    report({:embedded, texts, priority})
    respond(texts, :persistent_term.get({__MODULE__, :fail}, false))
  end

  @impl true
  def model_name, do: :persistent_term.get({__MODULE__, :model}, "fake-test-model")

  defp report(message) do
    case :persistent_term.get({__MODULE__, :pid}, nil) do
      nil -> :ok
      pid -> send(pid, message)
    end
  end

  defp respond(_texts, true), do: {:error, :serving_down}
  defp respond(texts, false), do: {:ok, Enum.map(texts, fn _ -> @vector end)}
end
