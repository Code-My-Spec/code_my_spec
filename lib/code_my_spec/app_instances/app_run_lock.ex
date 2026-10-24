defmodule CodeMySpec.AppInstances.AppRunLock do
  @moduledoc """
  Which working copies have a start/restart/stop run of their own app in
  flight, right now -- and the guard that keeps a second one from starting
  alongside it.

  `stop_app`, `restart_app` and `ensure_app_running` used to run inline,
  inside the code-mode sandbox's 30s wall clock (issue f2977826, batch 2 of
  4f7929e4) -- `restart_app` and `ensure_app_running` raced that clock with a
  shrinking margin, `stop_app` declared the full 30s with none at all. Making
  all three genuinely async reopens a hazard synchronous calls never had: two
  overlapping runs against the same working copy's app -- a restart racing
  another restart's own `_build` directory, or a stop racing a start -- where
  a synchronous caller previously had no way to even issue the second call
  before the first returned. One lock per working copy, shared by all three
  tools, closes that.

  Same Registry-based design as `CodeMySpec.Provisioning.RunLock` (a crashed
  holder releases the lock by dying, not by an `after` block that never ran;
  see that module's own moduledoc for why a Registry and not a database row).
  Kept as its own module rather than a new cross-boundary dependency on
  `Provisioning` -- `WorkingCopies` has never depended on it, and this is a
  different kind of in-flight work: one working copy's own app, not a
  project's provider-facing setup.
  """

  @doc "Child spec for the application supervision tree."
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  @doc """
  Run `fun` with `instance_id`'s lock held, or refuse without running it.

  Returns `{:error, {:already_running, started_at}}` immediately, without
  ever calling `fun`, when another process already holds the lock for this
  working copy. Otherwise claims the lock as the calling process, runs `fun`
  with it held, and releases it afterwards whether `fun` succeeds, returns an
  error tuple, or raises.

  Must be called by the process that will actually do the work: the lock
  lives exactly as long as that process.

  `holder` names the agent that started the run (`:agent_id`) and what it
  started (`:label`), mirroring `Provisioning.RunLock.with_lock/3`.
  """
  @spec with_lock(String.t(), (-> result), keyword()) ::
          result | {:error, {:already_running, DateTime.t() | nil}}
        when result: term()
  def with_lock(instance_id, fun, holder \\ []) when is_function(fun, 0) do
    meta = %{
      started_at: DateTime.utc_now(),
      agent_id: Keyword.get(holder, :agent_id),
      label: Keyword.get(holder, :label)
    }

    case Registry.register(__MODULE__, instance_id, meta) do
      {:ok, _owner} ->
        try do
          fun.()
        after
          Registry.unregister(__MODULE__, instance_id)
        end

      {:error, {:already_registered, _owner_pid}} ->
        {:error, {:already_running, in_flight(instance_id)}}
    end
  end

  @doc "When the in-flight run for `instance_id` started, or `nil` if none is running."
  @spec in_flight(String.t()) :: DateTime.t() | nil
  def in_flight(instance_id) do
    case Registry.lookup(__MODULE__, instance_id) do
      [{_pid, %{started_at: started_at}}] -> started_at
      [] -> nil
    end
  end
end
