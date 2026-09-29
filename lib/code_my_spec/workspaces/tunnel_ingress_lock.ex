defmodule CodeMySpec.Workspaces.TunnelIngressLock do
  @moduledoc """
  Which tunnel has an ingress read-modify-write in flight, right now — and the
  guard that keeps a second one from racing it.

  A shared tunnel's ingress list (criterion 1586) is state more than one
  working copy writes to independently: main's own rule is already there, and
  every other copy on its device adds its own the first time its app comes
  up. `PreviewTunnel.ensure/1`'s add is a GET-modify-PUT against Cloudflare's
  remote configuration endpoint, not a single atomic write, so two copies
  racing it would both GET the same list, each add their own rule in memory,
  and the second PUT would silently drop the first copy's — a preview that
  worked for a moment and then stopped resolving, for no reason visible on
  either copy's side.

  Same shape and same reasoning as `CodeMySpec.Promotion.Lock`: refuses
  rather than queues, because a queued write whose caller has since moved on
  (a copy whose app was restarted with a new port before its turn came up)
  would still land, aimed at a service that no longer exists. `ensure/1` is
  already safe to retry — a caller who gets refused just calls it again.

  Keyed on `tunnel_id`, not on project or device: two different tunnels on
  the same device never contend for the same ingress list, and locking any
  wider than the resource actually being mutated would refuse writes that
  were never going to race each other.
  """

  @doc "Child spec for the application supervision tree."
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  @doc """
  Run `fun` with `tunnel_id`'s ingress lock held, or refuse without running
  it.

  Returns `{:error, {:tunnel_busy, started_at}}` immediately, without ever
  calling `fun`, when another process already holds the lock for this
  tunnel. Otherwise claims the lock as the calling process, runs `fun` with
  it held, and releases it afterwards whether `fun` succeeds, returns an
  error tuple, or raises.
  """
  @spec with_lock(String.t(), (-> result)) ::
          result | {:error, {:tunnel_busy, DateTime.t() | nil}}
        when result: term()
  def with_lock(tunnel_id, fun) when is_binary(tunnel_id) and is_function(fun, 0) do
    case Registry.register(__MODULE__, tunnel_id, %{started_at: DateTime.utc_now()}) do
      {:ok, _owner} ->
        try do
          fun.()
        after
          Registry.unregister(__MODULE__, tunnel_id)
        end

      {:error, {:already_registered, _owner_pid}} ->
        {:error, {:tunnel_busy, in_flight(tunnel_id)}}
    end
  end

  @doc "When the in-flight ingress write for `tunnel_id` started, or `nil` if none is running."
  @spec in_flight(String.t()) :: DateTime.t() | nil
  def in_flight(tunnel_id) do
    case Registry.lookup(__MODULE__, tunnel_id) do
      [{_pid, %{started_at: started_at}}] -> started_at
      [] -> nil
    end
  end
end
