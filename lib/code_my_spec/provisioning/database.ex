defmodule CodeMySpec.Provisioning.Database do
  @moduledoc """
  The database each environment's app talks to.

  - **One container per box, shared.** `ensure_container/2` starts
    `cms-postgres` once per box and never restarts a running one out from
    under another project's connections.
  - **One tenant per project and environment.** `serve/3` gives each its own
    role (`app_<project>`) and database (`app_<project>_<environment>`), and
    never touches another project's.
  - **An account-grained administrator** (`AccountSecrets`) creates tenants:
    the image only creates the role named by `POSTGRES_USER` at first boot.
  - **The URL is a secret**: passwords live in `ProjectSecrets` and the URL
    goes into the environment's encrypted env, never the working tree.
  - **A separate restore role** (`app_<project>_restore`, `CREATEDB` only)
    makes and drops `bin/backup restore`'s scratch database. The app's own
    role never gets `CREATEDB`.

  See knowledge/provisioning, "Database".
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

  # `/var/lib/postgresql`, not `.../data`: pg18's image refuses to start when
  # a volume is mounted one level too deep (docker-library/postgres#1259).
  @volume_mount "/var/lib/postgresql"
  @port 5432

  @admin_username "postgres"
  @admin_password_secret "database_admin_password"

  # Pinned: a database that silently changes major version between runs is a
  # data-loss event. pgvector is a strict superset of stock postgres, so one
  # box serves tenants that need `vector` and tenants that do not.
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

  Per environment, so UAT's password does not open production's; per
  project, so two projects' `prod` cannot collide on a shared box.
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

  @doc """
  This environment's restore-verification credential, minted once.

  A second role, not the app's own. It owns no fixed database, only
  `CREATEDB`, so there is no `:database`.
  """
  @spec restore_credential(Scope.t(), String.t()) ::
          {:ok, %{username: String.t(), password: String.t()}} | {:error, term()}
  def restore_credential(%Scope{} = scope, environment) do
    name = "database_restore_password_#{environment}"

    case ProjectSecrets.fetch_value(scope, name) do
      {:ok, password} when is_binary(password) and password != "" ->
        {:ok, describe_restore(scope, password)}

      _ ->
        password = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

        with {:ok, _} <- ProjectSecrets.put_value(scope, name, password) do
          {:ok, describe_restore(scope, password)}
        end
    end
  end

  # Can create and alter any project's role or database on the box.
  # Account-grained, like the server access key.
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
  network, and an address would change when either is recreated.
  """
  @spec url(%{username: String.t(), password: String.t(), database: String.t()}) :: String.t()
  def url(%{username: username, password: password, database: database}) do
    "ecto://#{username}:#{password}@#{@container}/#{database}"
  end

  @doc """
  The throwaway database `bin/backup restore` proves a dump into.

  Per tenant and environment: a restore role can only drop a database it
  owns, so one shared name would lock out every project after the first.
  """
  @spec scratch_database(Scope.t(), String.t()) :: String.t()
  def scratch_database(%Scope{} = scope, environment) do
    "app_#{tenant_slug(scope)}_#{environment}_restore_check"
  end

  @doc """
  What `bin/backup restore` connects with to create and drop its own
  scratch database.

  Always `postgres`, the default maintenance database: this role owns no
  fixed one.
  """
  @spec restore_url(%{username: String.t(), password: String.t()}) :: String.t()
  def restore_url(%{username: username, password: password}) do
    "ecto://#{username}:#{password}@#{@container}/postgres"
  end

  @doc """
  Start the box-wide database container, account-side.

  Brings up the container once per box, plus the `vector` extension on
  `template1` that every tenant database inherits. Idempotent — an
  already-running container is left alone (but its image is checked).

  `:run` takes the command and returns `{output, status}`, so what we ask the
  box to do is assertable without a box.
  """
  @spec ensure_container(Scope.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ensure_container(%Scope{} = scope, opts \\ []) do
    run = Keyword.fetch!(opts, :run)

    with {:ok, admin} <- serve_admin_credential(scope, opts),
         :ok <- ensure_container(run, admin, opts),
         :ok <- await_ready(run, Keyword.get(opts, :database_attempts, 30)),
         :ok <- ensure_template_vector_extension(run, admin) do
      {:ok, %{host: @container, port: @port}}
    end
  end

  @doc """
  Give this environment its own role and database on an already-running
  shared container.

  Never starts the container: refuses with `:database_not_provisioned` if it
  is not up, so a project's step cannot stand up shared account
  infrastructure as a side effect.

  Idempotent: this project's role and database are created only if absent,
  and passwords are re-synced every time.

  `:run` takes the command and returns `{output, status}`, so what we ask the
  box to do is assertable without a box.
  """
  @spec serve(Scope.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def serve(%Scope{} = scope, environment, opts \\ []) do
    run = Keyword.fetch!(opts, :run)

    with {:ok, admin} <- serve_admin_credential(scope, opts),
         {:ok, credential} <- serve_credential(scope, environment, opts),
         {:ok, restore} <- serve_restore_credential(scope, environment, opts),
         true <- container_running?(run) || {:error, :database_not_provisioned},
         :ok <- ensure_tenant(run, admin, credential),
         :ok <- sync_password(run, credential),
         :ok <- ensure_restore_role(run, admin, restore),
         :ok <- sync_restore_password(run, restore) do
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

  defp serve_restore_credential(scope, environment, opts) do
    case Keyword.get(opts, :database_restore_credential) do
      %{username: _, password: _} = restore -> {:ok, restore}
      _ -> restore_credential(scope, environment)
    end
  end

  # Only creates when not already running: an unconditional `docker rm -f`
  # would restart another project's database under its live connections.
  defp ensure_container(run, admin, opts) do
    if container_running?(run) do
      check_image(run, opts)
    else
      create_container(run, admin, opts)
    end
  end

  # A running container on a different image is reported as
  # `:database_image_outdated`, never fixed here: swapping it means wiping a
  # volume that may hold another project's data. An unreadable inspect
  # proceeds rather than blocking on an SSH hiccup.
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

  # Counts only container-id lines, so an ssh banner on the same stream cannot
  # read as "running".
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

  # Bound to the docker network only, never a host port. Bootstrapped with
  # the administrator, since later tenants' roles cannot be the one the
  # container was born with.
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

  # `docker run -d` returning 0 means created, not accepting connections.
  # Asks the server, not a role, since tenants may not exist yet.
  defp await_ready(run, attempts) do
    # `-h 127.0.0.1`: the unix socket is up during first boot while TCP still
    # refuses, and the app connects over TCP.
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

  # This project's role and database, created on its first visit to the box.
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

  # `CREATE DATABASE` cannot run inside a `DO` block (transaction), so
  # existence is checked in the shell first.
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

  # pgvector is not a trusted extension, so a tenant role cannot install it
  # even as owner. The admin installs it; the app's own
  # `CREATE EXTENSION IF NOT EXISTS vector` migration then succeeds.
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

  # The restore's scratch database exists only during a restore, so the
  # extension is installed into `template1`, which `CREATE DATABASE` clones.
  # `IF NOT EXISTS` makes every call after the first a no-op.
  defp ensure_template_vector_extension(run, admin) do
    sql = "CREATE EXTENSION IF NOT EXISTS vector"

    command =
      "docker exec #{@container} psql -v ON_ERROR_STOP=1 -U #{shell_escape(admin.username)} " <>
        "-d #{shell_escape("template1")} -c #{shell_escape(sql)} > /dev/null"

    case run.([command]) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:database_template_not_ready, status, String.trim(output)}}
    end
  end

  # Make the role's password the one `DATABASE_URL` carries.
  # `POSTGRES_PASSWORD` is read only when the data directory is initialised,
  # and the named volume outlives the container, so a rotated password would
  # otherwise surface at deploy as `28P01 password authentication failed`.
  # Runs every time; checking would cost the same round trip.
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

  # Unconditional, so a role created before `CREATEDB` was granted picks it up
  # on a later run. `CREATEDB` here, never in `ensure_role/3`.
  defp ensure_restore_role(run, admin, restore) do
    sql =
      "DO $$ BEGIN " <>
        "IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = #{sql_escape(restore.username)}) THEN " <>
        "CREATE ROLE #{restore.username} LOGIN PASSWORD #{sql_escape(restore.password)}; " <>
        "END IF; END $$; " <>
        "ALTER ROLE #{restore.username} CREATEDB;"

    run_admin_sql(run, admin, sql, :database_restore_role_not_ready)
  end

  # As `sync_password/2`, through `-d postgres`: this role owns no database.
  defp sync_restore_password(run, restore) do
    sql = "ALTER USER #{restore.username} WITH PASSWORD #{sql_escape(restore.password)}"

    command =
      "docker exec #{@container} psql -v ON_ERROR_STOP=1 -U #{shell_escape(restore.username)} " <>
        "-d postgres -c #{shell_escape(sql)} > /dev/null"

    case run.([command]) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:error, {:database_restore_password_not_set, status, String.trim(output)}}
    end
  end

  defp describe(scope, password, environment) do
    slug = tenant_slug(scope)
    %{username: "app_#{slug}", password: password, database: "app_#{slug}_#{environment}"}
  end

  defp describe_restore(scope, password) do
    %{username: "app_#{tenant_slug(scope)}_restore", password: password}
  end

  # Interpolated unquoted into `CREATE ROLE`/`CREATE DATABASE`, so restricted
  # to an unquoted identifier: `Repository.default_name/1`'s output with dashes
  # converted, or a deterministic fallback when that is empty.
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
