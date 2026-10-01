defmodule CodeMySpec.Provisioning.RunLock do
  @moduledoc """
  Which projects have a setup run in flight, right now — and the guard that
  keeps a second one from starting alongside it.

  `run_devops_setup` used to have no way to tell its caller "still working on
  it" — the MCP transport's call timeout is far shorter than a real run
  (deploy alone measured ~167s), so an agent that saw the timeout as failure
  retried, and `Resources.fix/2`/`Provisioning.run/3` had nothing stopping
  the retry from starting a second run against the same project's real
  Cloudflare/Hetzner/Resend/GitHub state while the first was still going.
  Observed live: a step's state flipping `:done -> :errored -> :done` on
  nothing but two runs racing each other's writes, and a genuine Hetzner
  `409 server name is already used` very plausibly from two runs racing the
  same server-creation slot.

  ## Why a Registry, not a database row

  A row would need something to clear it when the holder crashes — a
  supervisor exit that never reaches its `after` block leaves a permanent
  lock nothing can take back. `Registry.register/3` ties the entry to the
  registering process by monitor: it is gone the instant that process is,
  crash or not, and a server restart comes back with an empty table, which is
  true — nothing is running any more. Same reasoning as
  `CodeMySpec.Files.ReconcileRegistry`, which tracks a different kind of
  in-flight work the same way.

  ## The lock is the atomicity, not a check before one

  `Registry.register/3` for `keys: :unique` is a single atomic decision: of
  two processes racing to register the same key, exactly one gets `{:ok, _}`
  and the other gets `{:error, {:already_registered, _}}`, with no window
  between "checked" and "claimed" for a second caller to slip through. A
  separate `in_flight?/1` read followed by a conditional register would have
  exactly that window — which is the shape of race this module exists to
  close, so `with_lock/2` never offers it as two calls.
  """

  @doc "Child spec for the application supervision tree."
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  @doc """
  Run `fun` with `project_id`'s lock held, or refuse without running it.

  Returns `{:error, {:already_running, started_at}}` immediately, without
  ever calling `fun`, when another process already holds the lock for this
  project. Otherwise claims the lock as the calling process, runs `fun` with
  it held, and releases it afterwards whether `fun` succeeds, returns an
  error tuple, or raises — a run that blows up must not leave the project
  permanently locked out from ever running again.

  Must be called by the process that will actually do the work: the lock
  lives exactly as long as that process, which is what makes release
  automatic rather than something every caller has to remember.

  `holder` names the agent that started the run (`:agent_id`) and what it
  started (`:label`), so `held_by/1` can say that agent is waiting on it.
  """
  @spec with_lock(Ecto.UUID.t(), (-> result), keyword()) ::
          result | {:error, {:already_running, DateTime.t() | nil}}
        when result: term()
  def with_lock(project_id, fun, holder \\ []) when is_function(fun, 0) do
    meta = %{
      run_id: new_run_id(),
      started_at: DateTime.utc_now(),
      agent_id: Keyword.get(holder, :agent_id),
      label: Keyword.get(holder, :label)
    }

    case Registry.register(__MODULE__, project_id, meta) do
      {:ok, _owner} ->
        try do
          fun.()
        after
          Registry.unregister(__MODULE__, project_id)
        end

      {:error, {:already_registered, _owner_pid}} ->
        {:error, {:already_running, in_flight(project_id)}}
    end
  end

  @doc "When the in-flight run for `project_id` started, or `nil` if none is running."
  @spec in_flight(Ecto.UUID.t()) :: DateTime.t() | nil
  def in_flight(project_id) do
    case Registry.lookup(__MODULE__, project_id) do
      [{_pid, %{started_at: started_at}}] -> started_at
      [] -> nil
    end
  end

  @doc """
  The id of the run the calling process is doing the work of, or nil.

  Only when the lock holder is this process or one it was started from
  (`$callers`/`$ancestors`) — a run some other process holds for the same
  project is not this caller's, and labelling a box with it would claim
  ownership on that run's behalf.
  """
  @spec caller_run_id(Ecto.UUID.t() | nil) :: String.t() | nil
  def caller_run_id(nil), do: nil

  def caller_run_id(project_id) do
    lineage = [self() | Process.get(:"$callers", [])] ++ Process.get(:"$ancestors", [])

    case Registry.lookup(__MODULE__, project_id) do
      [{pid, %{run_id: run_id}}] -> if pid in lineage, do: run_id
      _ -> nil
    end
  end

  @doc """
  Whether run `run_id` of `project_id` still holds the lock, anywhere in the
  cluster.

  `:in_flight` when some node's lock for the project is held by that run,
  `:ended` when every node answered and none is, `:unknown` when a node could
  not be asked — an unanswered node may be the one running it, so that is not
  evidence the run is over.
  """
  @spec run_state(Ecto.UUID.t(), String.t()) :: :in_flight | :ended | :unknown
  def run_state(project_id, run_id) do
    remote = :erpc.multicall(Node.list(), __MODULE__, :local_run_id, [project_id], 5_000)
    answers = [{:ok, local_run_id(project_id)} | remote]

    cond do
      Enum.any?(answers, &match?({:ok, ^run_id}, &1)) -> :in_flight
      Enum.all?(answers, &match?({:ok, _}, &1)) -> :ended
      true -> :unknown
    end
  end

  @doc false
  # Called over `:erpc` by `run_state/2` on every node, this one included.
  @spec local_run_id(Ecto.UUID.t()) :: String.t() | nil
  def local_run_id(project_id) do
    case Registry.lookup(__MODULE__, project_id) do
      [{_pid, %{run_id: run_id}}] -> run_id
      [] -> nil
    end
  end

  defp new_run_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  @doc "The run `agent_id` started that is still in flight, or nil."
  @spec held_by(Ecto.UUID.t() | nil) ::
          %{project_id: Ecto.UUID.t(), label: String.t() | nil, started_at: DateTime.t()} | nil
  def held_by(nil), do: nil

  def held_by(agent_id) do
    __MODULE__
    |> Registry.select([{{:"$1", :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.find_value(fn
      {project_id, %{agent_id: ^agent_id} = meta} ->
        %{project_id: project_id, label: meta.label, started_at: meta.started_at}

      _other ->
        nil
    end)
  end
end
