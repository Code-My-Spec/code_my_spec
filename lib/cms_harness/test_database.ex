defmodule CmsHarness.TestDatabase do
  @moduledoc """
  A test database per working copy, so the analyzer's answer is about the tree
  it was pointed at.

  ## The failure this exists to stop

  `mix test` uses whatever database `config/test.exs` names, and on a machine
  running several agents that is one database shared by every checkout.
  Whichever one migrated last wins and the others inherit its schema.

  Measured here, same commit, same suite: **36 failures** on the shared database
  and **1** on its own. The whole difference was one column — `conversations.type`,
  `NOT NULL`, added by a branch this checkout does not have. Every insert on this
  branch then died, and the stop hook reported ~25 failures across four test
  files as though this branch had broken them.

  That is worse than slow. The analyzer's verdict is what the harness is *for*,
  and an agent that believes it will start repairing code that was never broken.
  Nothing in the output distinguishes "your code is wrong" from "this database is
  not yours".

  ## Per working copy, not per project

  Two worktrees of one project is the ordinary case — a branch each — and they
  need different schemas at the same time, which is exactly what a project-keyed
  name would deny them. So the partition is derived from the absolute path of the
  working copy.

  ## It names the database and does not manage it

  This used to create and migrate the partition too, and both of those shelled
  out to `mix` with an environment `Environments.clean_otp_env/0` had scrubbed
  `MIX_ENV` out of — so they ran against **dev**, the database every agent
  shares. A sibling truncate emptied it three times on 2026-08-13.

  Now it computes a name and nothing else. Nothing in this project migrates or
  truncates a database from code; `Mix.Tasks.Cms.CheckTestMigrations` already
  held that line — "a refusal rather than an alias that migrates" — and this
  module was the exception to it.

  A database that does not exist fails the run with the child's own "database
  does not exist", which names itself and is answered by a human with
  `MIX_ENV=test mix ecto.create`. That is a worse first run and a much better
  failure mode than a background process with DDL rights on a shared server.
  """

  alias ClientUtils.Harness.Onboarding

  @doc """
  Environment for a `mix test` in `env` — the partition name, and nothing else.

  Returns `[]` for an environment with no working directory, which is the signal
  to run against whatever the project already uses.

  `build_env` is accepted and ignored. It mattered when this shelled out to
  `mix`; it is kept so callers do not have to change, and because a two-arity
  version of this would be the only difference between the harness's call site
  and a future one that needs it back.
  """
  @spec env(CodeMySpec.Environments.Environment.t(), [{String.t(), String.t()}], String.t() | nil) ::
          [{String.t(), String.t()}]
  def env(environment, build_env \\ [], source \\ nil)

  # Names the partition and nothing else. It used to create and migrate the
  # database too, and that is gone — see the note below `env/3`.
  def env(%{cwd: cwd}, _build_env, source) when is_binary(cwd) do
    [{"MIX_TEST_PARTITION", partition_for(cwd, source)}]
  end

  def env(_environment, _build_env, _source), do: []

  @doc """
  The partition name for a working copy — **read, never derived**.

  Delegates to `ClientUtils.Harness.Onboarding.resolve_partition!/2`, which returns
  what onboarding recorded and raises for a copy that has none, naming the command
  that fixes it.

  One path, deliberately. This used to digest the cwd here, with an identical
  digest in client_utils, so the analyzer ignored whatever onboarding wrote and the
  two agreed only because one algorithm had been written twice (acaf8035). A
  derive-on-miss fallback would have kept both alive for exactly the copies nobody
  had onboarded — silently, which is how the first pair survived.

  Short, stable, and derived from the absolute path — two worktrees of one
  project get different databases, and the same worktree gets the same one
  across restarts so the migrate is paid once.
  """
  @spec partition_for(String.t()) :: String.t()
  def partition_for(cwd) do
    Onboarding.resolve_partition!(cwd)
  end

  @doc """
  The partition name for a working copy and one analyzer source.

  Each suite that can run concurrently gets its own; anything else keeps the
  shared one.

    <partition>    the interactive session's `mix test`
    <partition>s   the analyzer's spex run
    <partition>a   the analyzer's exunit run

  `Analysis` enqueues compiler, exunit and spex together, so exunit and spex
  suites run at the same time — and they ran against one database. Symptom
  (`bcad622d`): a sweep truncates before exunit and rows appear *during* it. 13
  committed `requirements` rows against an empty `projects` table, orphans of a
  project that no longer exists, and 17 failures in a file whose suite had
  passed 3,936/0 two minutes earlier. Failures that name files the session
  never touched and read exactly like real ones.

  **exunit moves too, and this paragraph used to argue it should not.** The
  original reasoning — "only spex moves; giving exunit a new name would orphan
  the database it has and force a fresh `ecto.create` + `ecto.migrate`, measured
  at 37.6s; spex pays that once and nothing else pays it at all" — costed the
  change correctly while answering a narrower question. It compared the
  analyzer's two suites to each other and missed the collision between the
  analyzer's exunit and **the agent's own interactive `mix test`**.

  Those shared a database, and not by accident: `mix cms.harness.onboard` writes
  `MIX_TEST_PARTITION` into `.claude/settings.local.json`'s `env` block so
  `resolve_partition!/2` can read it back, and Claude Code exports that block
  into the session. So an agent running `mix test` during a sweep got
  `bcad622d`'s exact shape, and it failed in the direction of "your branch broke
  these tests". The 37.6s is now knowingly paid, once per working copy.

  Ordering matters if this is ever changed again: `Onboarding.databases/2` is
  what tells anyone a database exists, and nothing creates them — see the note
  under the moduledoc. A partition used here and absent there is a database
  nobody is told to create. That is why `client_utils` is a git dependency
  rather than a hex one; a release boundary between these two is a window where
  the analyzer runs against a database no one has made.

  Deliberately a stopgap. The intent is to move `mix test` arbitration into our
  own analyzer — which already owns the run ledger and writes to Problems —
  rather than leaving client_utils to arbitrate it through an environment
  variable Claude Code happens to export. Nothing expensive should be built on
  this suffix.

  The suffix rather than a separate digest so the three stay visibly related —
  `h1a2b3c4d`, `h1a2b3c4ds` and `h1a2b3c4da` are recognisably one working copy
  when you are looking at a list of databases wondering which to drop.
  """
  @spec partition_for(String.t(), String.t() | nil) :: String.t()
  def partition_for(cwd, "spex"), do: partition_for(cwd) <> "s"
  def partition_for(cwd, "exunit"), do: partition_for(cwd) <> "a"
  def partition_for(cwd, _source), do: partition_for(cwd)

  @maintenance_database "postgres"
  @probe_timeout_ms 1_000

  @doc """
  Which of `names` exist on the Postgres these databases would live on.

  Reading, not managing. The moduledoc above is emphatic that nothing here
  creates, migrates or drops a database, and this does not change that: one
  `SELECT datname FROM pg_database` on a connection that is opened, asked and
  closed. It has no DDL to issue and cannot acquire any.

  It exists because naming a database and never asking whether it is there
  produced its own failure. `mix cms.harness.onboard` printed six commands and
  reported the copy onboarded whether or not anybody ran them, so "onboarded"
  and "usable" came apart with no way to tell from the outside — the missing
  database surfaced later as `undefined_column`, or as a suite that would not
  start, wearing a different failure's costume. That is story 1013's own
  complaint about everything else, reproduced by the task that fixed it.

  **Three answers, not two.** A server that cannot be reached returns
  `{:error, reason}` and never "none of them exist": an unreachable Postgres is
  the absence of an answer, and reporting it as absence-of-databases would send
  the reader to create three databases that may already be there. `devops_status`
  splits missing from unreachable for the same reason and it is the same mistake.

  Connection parameters come from this project's configured repo with the
  database swapped for the maintenance one, because `config/test.exs` and
  `config/dev.exs` name the same server and differ only in `database:` — which
  is the field being asked about, so it is the one field that cannot be
  inherited.

  `overrides` replaces connection parameters for one call. It exists so the
  unreachable branch can be exercised by naming a port nothing is listening on,
  rather than by mutating this node's application environment — which is the
  whole `Repo` config, shared with everything else running at the time.
  """
  @spec existence([String.t()], keyword()) ::
          {:ok, %{String.t() => boolean()}} | {:error, String.t()}
  def existence(names, overrides \\ []) when is_list(names) do
    with {:ok, _apps} <- Application.ensure_all_started(:postgrex),
         {:ok, conn} <- connect(overrides) do
      result = present(conn, names)
      GenServer.stop(conn, :normal, 1_000)
      result
    end
  end

  # Default backoff on purpose. `backoff_type: :stop` would read better — ask
  # once, give up — but `start_link` links the connection to whoever called
  # this, so a Postgres that is down would take the mix task down with it
  # rather than being reported. Retrying quietly and letting the queue time out
  # turns the same condition into a return value.
  defp connect(overrides) do
    opts =
      :code_my_spec
      |> Application.get_env(CodeMySpec.Repo, [])
      |> Keyword.take([:username, :password, :hostname, :port, :socket_dir, :ssl])
      |> Keyword.merge(overrides)
      |> Keyword.merge(
        database: @maintenance_database,
        pool_size: 1,
        queue_target: 500,
        queue_interval: 1_000
      )

    with :ok <- listening?(opts) do
      case Postgrex.start_link(opts) do
        {:ok, conn} -> {:ok, conn}
        {:error, reason} -> {:error, describe(reason)}
      end
    end
  end

  # Asked before Postgrex, because Postgrex answers this question badly.
  #
  # A refused port reaches the caller as a queue timeout — three seconds of
  # retries, two `failed to connect` lines on the way, and a message that
  # recommends raising `pool_size` and tracking down slow queries. All of that
  # argues for a defect that is not the one in front of the reader, which is the
  # most expensive kind of wrong message: it is specific, confident, and about
  # something else. One `:gen_tcp.connect` says `:econnrefused` or `:nxdomain` in
  # under a second and says nothing else.
  #
  # Skipped entirely for a Unix socket, which has no host or port to probe —
  # there the queue timeout is the only answer available and is left alone.
  defp listening?(opts) do
    cond do
      opts[:socket_dir] || opts[:socket] ->
        :ok

      true ->
        host = to_charlist(opts[:hostname] || "localhost")
        port = opts[:port] || 5432

        case :gen_tcp.connect(host, port, [:binary, active: false], @probe_timeout_ms) do
          {:ok, socket} ->
            :gen_tcp.close(socket)
            :ok

          {:error, reason} ->
            {:error, "nothing answered at #{opts[:hostname] || "localhost"}:#{port} (#{reason})"}
        end
    end
  end

  defp present(conn, names) do
    case Postgrex.query(conn, "SELECT datname FROM pg_database", [], timeout: 5_000) do
      {:ok, %{rows: rows}} ->
        have = MapSet.new(rows, fn [name] -> name end)
        {:ok, Map.new(names, &{&1, MapSet.member?(have, &1)})}

      {:error, reason} ->
        {:error, describe(reason)}
    end
  end

  # DBConnection's pool-exhaustion prose is right for a busy pool and wrong for
  # every way this can fail, so it is not passed through. A single query on a
  # one-connection pool that never got a connection means the server did not let
  # us in; anything else keeps its own words.
  defp describe(%DBConnection.ConnectionError{message: message}) do
    case String.contains?(message, "connection not available") do
      true -> "could not open a connection (credentials, or the server refused it)"
      false -> message
    end
  end

  defp describe(%Postgrex.Error{postgres: %{message: message}}), do: message
  defp describe(reason), do: inspect(reason)
end
