defmodule CodeMySpecSpex.RecordingFlameBackend do
  @moduledoc """
  Wraps `FLAME.LocalBackend`, reporting every `remote_boot/1` to whoever is
  listening — the one moment any `FLAME.Backend` actually "goes" somewhere
  to run a job, which is the same step `CodeMySpec.Embeddings.HetznerFlameBackend`
  implements for real against a Hetzner box (story 877). Standing in for it
  here proves a bulk embed call reached the pool's own backend boot step —
  "work went to the burst box" — without needing SSH or a real Hetzner
  account in a spex (story 1087, criterion 1769).

  Delegates every other callback to `FLAME.LocalBackend` unchanged, so a job
  run through this backend still actually executes.
  """

  @behaviour FLAME.Backend

  @impl true
  def init(opts), do: FLAME.LocalBackend.init(opts)

  @impl true
  def remote_spawn_monitor(state, term), do: FLAME.LocalBackend.remote_spawn_monitor(state, term)

  @impl true
  def system_shutdown, do: FLAME.LocalBackend.system_shutdown()

  @impl true
  def remote_boot(state) do
    report(:booted)
    FLAME.LocalBackend.remote_boot(state)
  end

  @doc "Report every `remote_boot/1` to `pid` from now on."
  def listen(pid), do: :persistent_term.put({__MODULE__, :pid}, pid)

  @doc "Stop reporting."
  def reset, do: :persistent_term.erase({__MODULE__, :pid})

  defp report(event) do
    case :persistent_term.get({__MODULE__, :pid}, nil) do
      nil -> :ok
      pid -> send(pid, {__MODULE__, event})
    end
  end
end
