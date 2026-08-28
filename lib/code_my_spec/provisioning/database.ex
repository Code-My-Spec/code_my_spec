defmodule CodeMySpec.Provisioning.Database do
  @moduledoc """
  The database each environment's app talks to.

  Nothing provisioned one before. `backups` ran `pg_dump` against a database
  that did not exist, the generated `config/deploy*.yml` put the app on a
  `db_net` network with nothing else on it, and the first deploy to reach
  kamal would have started a container that could not boot. A whole step was
  assumed everywhere and implemented nowhere.

  ## One box, shared — one role and one database per project

  The container is a box-wide singleton: whichever project's server step
  reaches this box first starts it, and every project after that reuses the
  one already running rather than restarting it out from under whoever else
  is connected. That is what makes the box shareable across projects at all —
  an account with two projects on one server is the ordinary case this exists
  for, not an edge case bolted on afterward.

  What is *not* shared is the tenant inside it: each project gets its own
  role and its own database per environment, named from the project so two
  projects' `prod` cannot collide (`app_<project>_<environment>`). Ensuring
  one project's role exists, or rotating its password, never touches another
  project's role — the shape `sync_password/2` already had for one project's
  own environments, extended one grain further.

  ## Bootstrapping a shared container needs an administrator

  The official Postgres image only creates the role and database named by
  `POSTGRES_USER`/`POSTGRES_DB` at first boot. Every tenant after the first
  cannot log in to create itself — nothing has granted it anything yet — so
  the box needs one administrator credential, minted once per account
  (`AccountSecrets`, the same grain the server access key uses: it opens
  every box the account owns), used only to create and alter each project's
  own role and database.

  ## The URL is a secret, and lives where the others do

  The password is generated once into `ProjectSecrets` and the connection URL
  is written into that environment's encrypted env, so the app reads it the
  same way it reads everything else. Nothing puts it in the working tree.
  """

  require Logger

  alias CodeMySpec.AccountSecrets
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.Repository
  alias CodeMySpec.Provisioning.Wait
  alias CodeMySpec.Users.Scope

  @container "cms-postgres"
  @network "db_net"
  @volume "cms-postgres-data"

  # `/var/lib/postgresql`, not `/var/lib/postgresql/data` — pg18's official
  # image moved to a `pg_ctlcluster`-style layout (`PGDATA` under
  # `/var/lib/postgresql/18/docker`) and now refuses to start at all when it
  # finds a volume mounted one level too deep, treating the old-style mount
  # point itself as evidence of a foreign layout rather than checking
  # whether anything is actually in it. Found live: cms-postgres crash-
  # looped on a brand new, empty volume — mount depth was the whole
  # complaint, not any data. docker-library/postgres#1259.
  @volume_mount "/var/lib/postgresql"
  @port 5432

  @admin_username "postgres"
  @admin_password_secret "database_admin_password"

  # Pinned rather than `:latest`, because a database that silently changes
  # major version between two runs of setup is a data-loss event with a
  # convenient explanation.
  #
  # pgvector, not stock postgres: it is a strict superset (the extension
  # only matters to a project that creates it) and MarketMySpec's own
  # database already depends on `vector` — the same box has to be able to
  # serve either kind of tenant without a special case for which one.
  @image "pgvector/pgvector:pg18"

  @doc "The container the app connects to, and the port it listens on."
  @spec host() :: String.t()
  def host, do: @container

  @spec port() :: pos_integer()
  def port, do: @port

  @doc "The docker network the app and the database share."
  @spec network() :: String.t()
  def network, do: @network

  @doc """
  This environment's database credential, minted once.

  Per environment, so UAT's password does not open production's — the same
  separation the age keys have, and for the same reason. Per project too, now
  that the box behind it can be shared: the role and database are both named
  from the project, so two projects' `prod` cannot collide or answer to each
  other's password.
  """
  @spec credential(Scope.t(), String.t()) ::
          {:ok, %{username: String.t(), password: String.t(), database: String.t()}}
          | {:error, term()}
  def credential(%Scope{} = scope, environment) do
    name = "database_password_#{environment}"

    case ProjectSecrets.fetch_value(scope, name) do
      {:ok, password} when is_binary(password) and password != "" ->
        {:ok, describe(scope, password, environment)}

      _ ->
        password = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

        with {:ok, _} <- ProjectSecrets.put_value(scope, name, password) do
          {:ok, describe(scope, password, environment)}
        end
    end
  end

  # The administrator that can create and alter *any* project's role or
  # database on this box. Account-grained, like the server access key: it has
  # to open every box the account owns, not just the one the project that
  # happened to mint it was thinking of.
  defp admin_credential(scope) do
    case AccountSecrets.fetch_value(scope, @admin_password_secret) do
      {:ok, password} when is_binary(password) and password != "" ->
        {:ok, %{username: @admin_username, password: password}}

      _ ->
        password = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

        with {:ok, _} <- AccountSecrets.put_value(scope, @admin_password_secret, password) do
          {:ok, %{username: @admin_username, password: password}}
        end
    end
  end

  @doc """
  What the app puts in `DATABASE_URL`.

  By container name, not by address: the app and the database share a docker
  network, and an address would be a second thing to keep correct when either
  is recreated.
  """
  @spec url(%{username: String.t(), password: String.t(), database: String.t()}) :: String.t()
  def url(%{username: username, password: password, database: database}) do
    "ecto://#{username}:#{password}@#{@container}/#{database}"
  end

  @doc """
  Start this environment's database on its shared box.

  Idempotent at both grains: an already-running container is left alone
  rather than restarted out from under whichever other project is connected
  to it, and this project's own role/database are created only if they are
  not already there. Re-running setup must not be a way to lose data, or to
  interrupt someone else's.

  `:run` takes the command and returns `{output, status}`, so what we ask the
  box to do is assertable without a box.
  """
  @spec serve(Scope.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def serve(%Scope{} = scope, environment, opts \\ []) do
    run = Keyword.fetch!(opts, :run)

    with {:ok, admin} <- serve_admin_credential(scope, opts),
         {:ok, credential} <- serve_credential(scope, environment, opts),
         :ok <- ensure_container(run, admin, opts),
         :ok <- await_ready(run, Keyword.get(opts, :database_attempts, 30)),
         :ok <- ensure_tenant(run, admin, credential),
         :ok <- sync_password(run, credential) do
      {:ok, %{host: @container, port: @port, database: credential.database}}
    end
  end

  defp serve_admin_credential(scope, opts) do
    case Keyword.get(opts, :database_admin_credential) do
      %{username: _, password: _} = admin -> {:ok, admin}
      _ -> admin_credential(scope)
    end
  end

  defp serve_credential(scope, environment, opts) do
    case Keyword.get(opts, :database_credential) do
      %{username: _, password: _, database: _} = credential -> {:ok, credential}
      _ -> credential(scope, environment)
    end
  end

  # Only touches the container when it is not already there to touch. A box
  # with a second project on it has this called against an already-running
  # instance far more often than not, and the destructive form —
  # `docker rm -f` unconditionally, every run — is exactly what made this box
  # unshareable: whichever project provisioned second restarted the first
  # project's database out from under its live connections.
  defp ensure_container(run, admin, opts) do
    if container_running?(run) do
      check_image(run, opts)
    else
      create_container(run, admin, opts)
    end
  end

  # A running container is never assumed to be running the image this box
  # would create today. Found live: `cms-postgres` on fuellytics-prod was
  # started on plain `postgres:17` before pgvector became the default here,
  # and `ensure_container/3` treated "running" as the whole answer — every
  # run since would have kept reporting the server step done on a database
  # that could never install `vector`, because nothing re-created here once
  # a container exists.
  #
  # This does not act on the drift. Swapping the image under a running
  # container whose volume might hold another project's real data is a
  # deliberate `docker rm -f` plus volume wipe, not something a routine
  # `serve/3` call gets to decide on its own — the same reason this box
  # never restarts an already-running container in the first place. It only
  # makes the drift visible, as a step that fails to verify rather than one
  # that quietly reports done on a database this run never actually ensured.
  #
  # An inspect that cannot be read is not a verdict either way — the same
  # rule `run_step/3` already applies to a provider that could not be read —
  # so this proceeds rather than blocking on a transient SSH hiccup.
  defp check_image(run, opts) do
    wanted = Keyword.get(opts, :database_image, @image)

    case run.(["docker inspect --format '{{.Config.Image}}' #{@container}"]) do
      {output, 0} ->
        case String.trim(output) do
          ^wanted ->
            :ok

          running ->
            {:error,
             {:database_image_outdated,
              "#{@container} is running #{running}, not #{wanted} — recreate it " <>
                "deliberately, the volume may hold real data"}}
        end

      {output, status} ->
        Logger.warning(
          "[Database] could not read #{@container}'s running image (#{status}): #{String.trim(output)}"
        )

        :ok
    end
  end

  # `docker ps -q` answers with nothing but container ID lines when it
  # succeeds — but ssh's own "Warning: Permanently added ... to the list of
  # known hosts" banner merges onto the same stream (`stderr_to_stdout: true`)
  # on every call, since `UserKnownHostsFile=/dev/null` guarantees ssh never
  # finds a host already known. Checking "is the output non-empty" answered
  # that banner, not the container list — confirmed live: it read a fresh box
  # with nothing on it as already running, and `create_container/3` never ran
  # at all. `Remote.ssh_args/2` silences the banner at the source; this also
  # refuses to be fooled by anything else that might land on the same stream.
  defp container_running?(run) do
    case run.(["docker ps -q -f name=^/#{@container}$"]) do
      {output, 0} -> output |> container_ids() |> Enum.any?()
      _ -> false
    end
  end

  defp container_ids(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&(&1 =~ ~r/^[0-9a-f]{12,64}$/))
  end

  # Bound to the docker network only — never published to a host port. The
  # firewall would refuse it from outside anyway, and a database that is not
  # listening on an address is a database that cannot be reached by mistake.
  #
  # Bootstrapped with the administrator, not a tenant. The image only creates
  # the role and database named by `POSTGRES_USER`/`POSTGRES_DB` at first
  # boot, and the whole point of `ensure_tenant/3` running afterward is that
  # a second project's role does not exist yet — it cannot have been the one
  # the container was born with.
  defp create_container(run, admin, opts) do
    image = Keyword.get(opts, :database_image, @image)

    env =
      [{"POSTGRES_USER", admin.username}, {"POSTGRES_PASSWORD", admin.password}]
      |> Enum.map_join(" ", fn {name, value} -> "-e #{name}=#{shell_escape(value)}" end)

    command =
      "docker network create #{@network} >/dev/null 2>&1; " <>
        "docker rm -f #{@container} >/dev/null 2>&1; " <>
        "docker run -d --name #{@container} --restart always " <>
        "--network #{@network} " <>
        "-v #{@volume}:#{@volume_mount} " <>
        "#{env} #{image}"

    case run.([command]) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:database_start_failed, status, String.trim(output)}}
    end
  end

  # `docker run -d` returning 0 means the container was created. Postgres takes
  # seconds more to accept connections, and a migration that arrives first
  # fails in a way that reads like a broken image rather than an impatient
  # caller — the same distinction the registry's probe draws.
  #
  # Asks the server, not a role: `-U`/`-d` bound this to the one credential
  # already, but ensuring a *second* project's role and database is `serve/3`'s
  # next step, not something to have already happened by the time readiness is
  # checked — pg_isready with neither answers whether Postgres itself is up,
  # which is the only thing this gate needs to know.
  defp await_ready(run, attempts) do
    # `-h 127.0.0.1`, so this asks the TCP listener rather than the unix socket.
    # Without it `pg_isready` answers over the socket, which is up during
    # Postgres's first-boot phase while TCP still refuses — so `serve/3`
    # reported ready and the very next connection got
    # `connection to server at "cms-postgres" ... failed: Connection refused`.
    # The app connects over TCP, so TCP is what readiness has to mean.
    check = "docker exec #{@container} pg_isready -h 127.0.0.1 > /dev/null"

    case run.([check]) do
      {_output, 0} ->
        :ok

      _ when attempts > 1 ->
        Wait.sleep(2_000)
        await_ready(run, attempts - 1)

      _ ->
        {logs, _} = run.(["docker logs --tail 50 #{@container} 2>&1"])
        {:error, {:database_not_ready, @container, String.trim(logs)}}
    end
  end

  # This project's role and database, created if this is the first time this
  # project has reached this box. A box shared with another project already
  # has the container running and someone else's role in it by the time this
  # runs — creating is not a one-time event the way it was when the box and
  # the project were the same thing.
  defp ensure_tenant(run, admin, credential) do
    with :ok <- ensure_role(run, admin, credential),
         :ok <- ensure_database(run, admin, credential) do
      ensure_vector_extension(run, admin, credential)
    end
  end

  defp ensure_role(run, admin, credential) do
    sql =
      "DO $$ BEGIN " <>
        "IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = #{sql_escape(credential.username)}) THEN " <>
        "CREATE ROLE #{credential.username} LOGIN PASSWORD #{sql_escape(credential.password)}; " <>
        "END IF; END $$;"

    run_admin_sql(run, admin, sql, :database_role_not_ready)
  end

  # `CREATE DATABASE` cannot run inside the `DO` block above — Postgres
  # refuses it inside a transaction — so existence is checked first in the
  # shell rather than left to a database-already-exists error, which would
  # read as this step failing rather than as the ordinary case of a role
  # provisioning its second environment.
  defp ensure_database(run, admin, credential) do
    check =
      "docker exec #{@container} psql -v ON_ERROR_STOP=1 -U #{shell_escape(admin.username)} " <>
        "-tAc #{shell_escape("SELECT 1 FROM pg_database WHERE datname = '#{credential.database}'")}"

    case run.([check]) do
      {output, 0} ->
        if String.trim(output) == "1" do
          :ok
        else
          create = "CREATE DATABASE #{credential.database} OWNER #{credential.username}"
          run_admin_sql(run, admin, create, :database_role_not_ready)
        end

      {output, status} ->
        {:error, {:database_role_not_ready, status, String.trim(output)}}
    end
  end

  defp run_admin_sql(run, admin, sql, error_tag) do
    command =
      "docker exec #{@container} psql -v ON_ERROR_STOP=1 -U #{shell_escape(admin.username)} " <>
        "-c #{shell_escape(sql)} > /dev/null"

    case run.([command]) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {error_tag, status, String.trim(output)}}
    end
  end

  # pgvector is not a trusted extension — its control file carries no
  # `trusted = true` — so a tenant role can never install it itself, no
  # matter that it owns its own database: confirmed live, a plain LOGIN
  # role got "permission denied to create extension ... Must be superuser"
  # even as the database's owner. Installed here, once, by the admin the
  # box already trusts for exactly this reason. `IF NOT EXISTS` is what
  # then makes it safe for the tenant's own migration to ask for the same
  # extension again — confirmed live too, the permission check never runs
  # once the extension already exists, so the app's ordinary
  # `CREATE EXTENSION IF NOT EXISTS vector` migration succeeds under its own,
  # unprivileged role.
  defp ensure_vector_extension(run, admin, credential) do
    sql = "CREATE EXTENSION IF NOT EXISTS vector"

    command =
      "docker exec #{@container} psql -v ON_ERROR_STOP=1 -U #{shell_escape(admin.username)} " <>
        "-d #{shell_escape(credential.database)} -c #{shell_escape(sql)} > /dev/null"

    case run.([command]) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:database_role_not_ready, status, String.trim(output)}}
    end
  end

  # Make the role's password the one `DATABASE_URL` actually carries.
  #
  # `POSTGRES_PASSWORD` is read only when Postgres *initialises* a data
  # directory, and the volume deliberately outlives the container — that is the
  # point of naming it, so re-running setup is not a way to lose data. The
  # consequence is that on every serve after the first, the password in the
  # environment is decoration: the role keeps whatever it was created with.
  #
  # So a rotated password left the connection string and the database
  # disagreeing, with nothing reporting it. `serve/3` returned ready, the server
  # step recorded done, and the failure surfaced at the deploy as
  # `FATAL 28P01 password authentication failed for user "app"` — pointing at
  # the migration rather than at the step that had just certified the database.
  #
  # `ALTER USER` is idempotent and costs one exec against a container that is
  # already up, so it runs every time rather than only when a change is
  # suspected — detecting the mismatch would mean trying the password, which is
  # the same round trip for a worse guarantee.
  defp sync_password(run, credential) do
    sql = "ALTER USER #{credential.username} WITH PASSWORD #{sql_escape(credential.password)}"

    command =
      "docker exec #{@container} psql -v ON_ERROR_STOP=1 -U #{shell_escape(credential.username)} " <>
        "-d #{shell_escape(credential.database)} -c #{shell_escape(sql)} > /dev/null"

    case run.([command]) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:database_password_not_set, status, String.trim(output)}}
    end
  end

  defp describe(scope, password, environment) do
    slug = tenant_slug(scope)
    %{username: "app_#{slug}", password: password, database: "app_#{slug}_#{environment}"}
  end

  # Postgres identifiers built from the project's own name — `CREATE ROLE`
  # and `CREATE DATABASE` above interpolate this unquoted, so it is
  # restricted to what an unquoted identifier accepts rather than trusted to
  # already be safe. `Repository.default_name/1` already normalises to
  # lowercase letters, digits and dashes; only the dash needs converting; a
  # project named entirely with characters that normalise away would be an
  # empty identifier, so a short deterministic fallback keeps this a real
  # database name instead of a syntax error.
  defp tenant_slug(scope) do
    case scope.active_project |> Repository.default_name() |> String.replace("-", "_") do
      "" -> "project_#{scope.active_project.id |> to_string() |> String.slice(0, 8)}"
      slug -> slug
    end
  end

  # A SQL string literal, quoted for Postgres rather than for the shell. The
  # result is then shell-escaped by the caller, because it travels through
  # `docker exec … -c`.
  defp sql_escape(value), do: "'" <> String.replace(value, "'", "''") <> "'"

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
