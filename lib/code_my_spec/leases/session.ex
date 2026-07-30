defmodule CodeMySpec.Leases.Session do
  @moduledoc """
  Owns the database session that holds this harness's project leases.

  A Postgres advisory lock lives on a connection, and Postgres drops it the
  moment that connection closes. That is the whole mechanism: this process owns
  one connection, so **this process being alive is the lease**. A harness that
  panics, gets `docker rm -f`'d, or is OOM-killed releases its projects as its
  socket closes — no deadline to wait out, no heartbeat to miss, no clock to
  agree on.

  One connection for the harness rather than one per project. Advisory locks
  are per-session and a session can hold as many as it likes, so a laptop
  watching ten projects still costs one connection. That matters: the last time
  connections were the constraint it surfaced as "MCP server is down" rather
  than as anything about connections.

  Deliberately outside the Ecto pool. A pooled checkout is returned as soon as
  the query finishes, and returning the connection is exactly what would drop
  the lock.

  ## Non-Postgres repos

  SQLite has no advisory locks, and needs none: each harness has its own
  `cli.db`, so there is no shared Files table to corrupt and nothing to
  arbitrate. Every lock request is granted.
  """

  use GenServer

  require Logger

  # Namespace for the classid half of the advisory key, so CodeMySpec's locks
  # cannot collide with any other advisory lock taken against the same database.
  @classid 0x434D5301

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Take the lock for `project_id`, returning whether it was granted.

  `false` means another live session holds it. There is no queueing — a second
  harness should refuse to start, not wait for the first to finish.
  """
  @spec try_lock(String.t(), GenServer.name()) :: boolean()
  def try_lock(project_id, name \\ __MODULE__) do
    GenServer.call(name, {:try_lock, project_id})
  catch
    :exit, _ ->
      # No session process — a lone harness must keep working. The lease guards
      # against a specific corruption, it is not a precondition for running.
      Logger.warning("[Leases] no lease session running; proceeding without a lease")
      true
  end

  @doc "Give the lock back. Rarely needed — dying does this."
  @spec unlock(String.t(), GenServer.name()) :: :ok
  def unlock(project_id, name \\ __MODULE__) do
    GenServer.call(name, {:unlock, project_id})
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    repo = Keyword.get(opts, :repo, CodeMySpec.Repo)

    case repo.__adapter__() do
      Ecto.Adapters.Postgres ->
        config =
          repo.config()
          |> Keyword.take([
            :hostname,
            :port,
            :username,
            :password,
            :database,
            :ssl,
            :socket_options
          ])

        case Postgrex.start_link(config) do
          {:ok, conn} ->
            {:ok, %{conn: conn, adapter: :postgres}}

          {:error, reason} ->
            Logger.warning(
              "[Leases] could not open a lease session (#{inspect(reason)}) — " <>
                "project leases are not being enforced"
            )

            {:ok, %{conn: nil, adapter: :unavailable}}
        end

      _other ->
        {:ok, %{conn: nil, adapter: :no_shared_store}}
    end
  end

  @impl true
  def handle_call({:try_lock, _project_id}, _from, %{adapter: adapter} = state)
      when adapter in [:no_shared_store, :unavailable] do
    {:reply, true, state}
  end

  def handle_call({:try_lock, project_id}, _from, %{conn: conn} = state) do
    {classid, objid} = key(project_id)

    case Postgrex.query(conn, "SELECT pg_try_advisory_lock($1, $2)", [classid, objid]) do
      {:ok, %{rows: [[granted]]}} ->
        {:reply, granted, state}

      {:error, reason} ->
        Logger.warning("[Leases] lock query failed (#{inspect(reason)}) — proceeding")
        {:reply, true, state}
    end
  end

  def handle_call({:unlock, _project_id}, _from, %{adapter: adapter} = state)
      when adapter in [:no_shared_store, :unavailable] do
    {:reply, :ok, state}
  end

  def handle_call({:unlock, project_id}, _from, %{conn: conn} = state) do
    {classid, objid} = key(project_id)
    Postgrex.query(conn, "SELECT pg_advisory_unlock($1, $2)", [classid, objid])
    {:reply, :ok, state}
  end

  # Advisory locks are keyed by two int4s, so a project's uuid has to be
  # hashed. The classid half is a fixed namespace and the objid half is the
  # hash, which makes a collision mean "two projects on one database hashed the
  # same" rather than "somebody else's lock happened to use our number".
  defp key(project_id) do
    {@classid, :erlang.phash2(project_id, 2_147_483_647)}
  end
end
