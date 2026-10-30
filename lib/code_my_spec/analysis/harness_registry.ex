defmodule CodeMySpec.Analysis.HarnessRegistry do
  @moduledoc """
  Which working copies have a connected harness able to run analyzers, right now.

  A unique-key `Registry` keyed by working copy id, whose values are the
  harness channel processes themselves: an entry dies with its channel, so a
  hit is a liveness answer with nothing to clean up. A second registration
  from a different instance is refused (the channel is the lease).

  Started by `CodeMySpecWeb.Application`, not `Analysis.Supervisor`, because
  it serves projects whose analyzers do not run locally. A leaf boundary so
  `Agents`, `WorkingCopies` and the web layer can ask without depending on
  `Analysis`.
  """

  use Boundary, top_level?: true, deps: []

  require Logger

  @doc "Child spec for the application supervision tree."
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  @doc """
  Register the calling channel process as the executor for `working_copy_id`.

  Called from the harness channel at join. `instance` names the OS process
  holding the harness's socket and `root` its checkout. The same instance with
  the same root takes its registration back (evicting the old channel); the
  same instance with a different root is `{:error, {:id_collision, pid, root}}`;
  a different instance is `{:error, {:already_registered, pid}}`.
  See knowledge/analysis, "Harness registry".
  """
  @spec register_executor(String.t(), String.t() | nil, String.t() | nil) ::
          :ok | {:error, {:already_registered, pid()}} | {:error, {:id_collision, pid(), term()}}
  def register_executor(working_copy_id, instance \\ nil, root \\ nil) do
    key = to_string(working_copy_id)

    case Registry.register(__MODULE__, key, {instance, root}) do
      {:ok, _} -> :ok
      {:error, {:already_registered, pid}} -> take_over(key, pid, instance, root)
    end
  end

  @doc """
  Record that the calling channel's harness answers `verb` for this copy.

  An older harness logs an unknown push and never replies, so a caller that
  sent it one would wait out its whole timeout. Asking here first lets it
  pick a verb that harness has. Dies with the channel, like the executor slot.
  """
  @spec register_verb(String.t(), String.t()) :: :ok
  def register_verb(working_copy_id, verb) do
    _ = Registry.register(__MODULE__, {:verb, verb, to_string(working_copy_id)}, true)
    :ok
  end

  @doc """
  Record the models the calling channel's harness can run, per provider, as it
  reported them at join: `%{provider => [model ids]}`, only for providers whose
  list it could read. Dies with the channel.
  """
  @spec register_served_models(String.t(), %{String.t() => [String.t()]}) :: :ok
  def register_served_models(working_copy_id, models) when is_map(models) do
    _ = Registry.register(__MODULE__, {:served_models, to_string(working_copy_id)}, models)
    :ok
  end

  @doc """
  The models `provider` serves, from the first of `working_copy_ids` whose
  harness reported a list for it, or `:unknown`.
  """
  @spec served_models([String.t()], String.t()) :: [String.t()] | :unknown
  def served_models(working_copy_ids, provider) do
    Enum.find_value(working_copy_ids, :unknown, fn id ->
      case Registry.lookup(__MODULE__, {:served_models, to_string(id)}) do
        [{_pid, %{^provider => [_ | _] = models}} | _] -> models
        _ -> nil
      end
    end)
  end

  @doc "Whether the channel connected for this copy declared `verb` at join."
  @spec supports?(String.t(), String.t()) :: boolean()
  def supports?(working_copy_id, verb),
    do: Registry.lookup(__MODULE__, {:verb, verb, to_string(working_copy_id)}) != []

  @doc "Whether a harness serving this working copy is connected now."
  @spec connected?(Ecto.UUID.t()) :: boolean()
  def connected?(working_copy_id),
    do: Registry.lookup(__MODULE__, to_string(working_copy_id)) != []

  @doc "Whether any harness is registered with this server at all."
  @spec any_connected?() :: boolean()
  def any_connected?, do: Registry.count(__MODULE__) > 0

  @doc """
  Who holds this working copy's executor slot, for the refusal message.

  `instance` is what the harness called itself at join (typically its OS pid),
  or `nil` for a harness that predates the field.
  """
  @spec executor_holder(String.t()) :: {:ok, pid(), String.t() | nil} | :error
  def executor_holder(working_copy_id) do
    case Registry.lookup(__MODULE__, to_string(working_copy_id)) do
      [{pid, {instance, _root}} | _] -> {:ok, pid, instance}
      [] -> :error
    end
  end

  @doc """
  A machine that can host a new working copy for this project, if one is
  connected.

  Creating a copy has no id yet, so any connected copy among
  `working_copy_ids` with a known root stands for its machine; which one is
  deliberately not chosen by root or recency. `:none` is a refusal, not a wait.
  """
  @spec host_holder([String.t()]) :: {:ok, pid(), String.t()} | :none
  def host_holder(working_copy_ids) when is_list(working_copy_ids) do
    Enum.find_value(working_copy_ids, :none, fn id ->
      case Registry.lookup(__MODULE__, to_string(id)) do
        [{pid, {_instance, root}} | _] when is_binary(root) and root != "" ->
          {:ok, pid, root}

        _ ->
          nil
      end
    end)
  end

  # An unknown instance on either side is not evidence of sameness.
  defp take_over(_key, pid, nil, _root), do: {:error, {:already_registered, pid}}

  defp take_over(key, pid, instance, root) do
    case Registry.lookup(__MODULE__, key) do
      # Same process, same working copy: reconnecting to its own slot.
      [{^pid, {^instance, ^root}}] ->
        evict(key, pid, instance, root)

      # Same process, different working copy: collapsed ids. Refuse rather than
      # evict, or the two siblings evict each other in a loop.
      [{^pid, {^instance, held_root}}] ->
        {:error, {:id_collision, pid, held_root}}

      # It went between the register and the lookup. The slot is free now.
      [] ->
        register_executor(key, instance, root)

      _ ->
        {:error, {:already_registered, pid}}
    end
  end

  # Kill it and wait for the entry to actually clear. Registry unregisters on
  # the process's :DOWN, so registering before that lands would race and lose.
  defp evict(key, pid, instance, root) do
    Logger.info(
      "[Analysis] harness #{key} reconnected from #{instance}; taking back the " <>
        "registration held by its previous channel #{inspect(pid)}"
    )

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 -> Process.demonitor(ref, [:flush])
    end

    case Registry.register(__MODULE__, key, {instance, root}) do
      {:ok, _} -> :ok
      {:error, {:already_registered, other}} -> {:error, {:already_registered, other}}
    end
  end
end
