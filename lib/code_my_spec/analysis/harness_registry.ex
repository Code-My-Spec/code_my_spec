defmodule CodeMySpec.Analysis.HarnessRegistry do
  @moduledoc """
  Which projects have a light harness able to run analyzers for them, right now.

  A `Registry` keyed by project id, whose values are the channel processes
  themselves. That choice is the point: a harness stops being an executor the
  moment its channel process exits, with nothing to remember to clean up and no
  window in which the server would dispatch work to a machine that has gone.

  Unique keys, because two harnesses holding one project is already refused a
  layer up — the channel is the lease. A second registration failing is
  therefore a bug being caught, not a case to handle.

  Started by `CodeMySpecWeb.Application` rather than by `Analysis.Supervisor`:
  the analysis subtree runs only where analyzers execute locally, and the whole
  point of this table is projects where they do not.

  Its own leaf boundary, holding the functions that read and write it.
  "Which harness process serves this copy" is asked by `Agents`,
  `WorkingCopies`, `MainAgent` and the web layer as well as by `Analysis`;
  answered from inside `Analysis`, every one of them depended on analysis to
  ask it.
  """

  use Boundary, top_level?: true, deps: [], exports: :all

  require Logger

  @doc "Child spec for the application supervision tree."
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  @doc """
  Register the calling process as the executor for `project_id`.

  Called from the harness channel at join. The registration dies with the
  channel, which is what makes `remote_executor/1` a liveness answer rather than
  a stored one.

  `instance` names the OS process holding the harness's socket. A harness that
  reconnects presents the same `working_copy_id` as the registration it is colliding
  with — that id *is* the working copy, read from a file inside it — so the id
  alone cannot say whether this is a rival or the same process returning. The
  instance can, and a process is allowed to take its own registration back.

  It has to be, because the entry only dies with the channel, and a channel is
  only killed by its socket closing. A harness whose client-side channel went
  while the socket stayed open leaves an entry nothing will ever release, and
  the harness then queues behind its own ghost at the capped backoff forever —
  hooks refusing with `:not_connected` against a server answering 200. That was
  not a slow recovery, it was a permanent one, and only killing the harness
  process cleared it.

  A *different* instance is still refused: that is two harnesses on one
  `_build`, where two `mix test` runs corrupt it into reporting failures that
  are not in the code. Registered entries are always live — Registry drops them
  when the channel dies — so a live entry from another instance means a real
  rival, not a leftover.

  ## The instance is necessary and not sufficient

  It answers "same OS process", and one daemon serves several working copies.
  So two channels for *different checkouts* presented the same instance, and a
  guard meaning "this is me reconnecting" fired for a sibling — killing it. The
  victim rejoined and killed the other back, about once a second, until the
  process was restarted: 1078 evictions in one evening with every stop hook
  refused.

  It only got the chance because their ids had collapsed onto one — see
  `CmsHarness.HarnessConfig.read/1` — and with distinct ids these are different
  registry keys that never meet. This pairs the root with the instance anyway,
  so the day identity breaks again the answer is a refusal naming both roots
  rather than a loop that has to be diagnosed from the outside.
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

  @doc "Whether the channel connected for this copy declared `verb` at join."
  @spec supports?(String.t(), String.t()) :: boolean()
  def supports?(working_copy_id, verb),
    do: Registry.lookup(__MODULE__, {:verb, verb, to_string(working_copy_id)}) != []

  @doc "Whether any harness is registered with this server at all."
  @spec any_connected?() :: boolean()
  def any_connected?, do: Registry.count(__MODULE__) > 0

  @doc """
  Who is holding this working copy's executor slot, if anyone.

  Exists for the refusal message. "A second agent is refused" is only half of
  criterion 744; the half that matters to whoever hit it is *which* agent holds
  it, because the operator is looking at two processes and has to know which one
  to stop. The registry is the only place that knows, and the entry is live by
  construction — Registry drops it when the channel dies — so a hit here names a
  process that is really there.

  `instance` is what the harness called itself at join, typically its OS pid. It
  can be nil for a harness that predates the field, in which case the pid is all
  there is to say and is still better than "another harness".
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

  Every other request here is addressed to a checkout that exists —
  `executor_holder/1` takes the id and the registry is keyed on it. Creating a
  copy has no id yet, and the thing being asked for is not "do something to this
  checkout" but "make one on your disk". So the address is a *machine*, and any
  connected copy of the project stands for the machine it is on: its harness has
  the repository, so it can make a sibling worktree beside it.

  Any rather than a specific one, deliberately. Which checkout a harness happens
  to be holding says nothing about its fitness to host another, and picking by
  root or by last-seen is the inference story 963's designation rule exists to
  rule out. What matters is that something is there.

  `:none` when nothing is connected, which is a refusal rather than a wait: a
  request for a checkout that cannot be satisfied is refused, and no row is
  written for a directory nobody made (criterion 3094).
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

  # Only from the same instance, and only when we know both — an unknown
  # instance on either side is not evidence of sameness, and guessing wrong
  # here is the `_build` corruption the lock exists to prevent.
  defp take_over(_key, pid, nil, _root), do: {:error, {:already_registered, pid}}

  defp take_over(key, pid, instance, root) do
    case Registry.lookup(__MODULE__, key) do
      # Same process, same working copy: this is the harness reconnecting to its
      # own slot, which it is allowed to do.
      [{^pid, {^instance, ^root}}] ->
        evict(key, pid, instance, root)

      # Same process, *different* working copy. Not a reconnect — two checkouts
      # claiming one identity, which is only possible when something upstream
      # collapsed their ids. Refusing names both roots; evicting starts a loop
      # that has to be diagnosed from the outside.
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
