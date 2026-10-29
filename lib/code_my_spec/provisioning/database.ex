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
  - **Adopting an existing app copies its data in, once.** `import_from/4`
    dumps and restores a legacy database on the same box, reassigns
    ownership, and compares row counts; `imported?/3` is the same compare
    with nothing run, for `verify/3` and for a repeat caller to skip the work.

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

  @doc """
  Repair all existing app-owned tenant databases on a provisioned box.

  Run once per shared box through provisioning with its SSH `:run` runner.
  Safe to repeat; discovers database owners from PostgreSQL without changing
  passwords, creating databases, or restarting the shared container.
  """
  @spec repair_existing(Scope.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def repair_existing(%Scope{} = scope, opts) do
    run = Keyword.fetch!(opts, :run)

    with {:ok, admin} <- serve_admin_credential(scope, opts),
         true <- container_running?(run) || {:error, :database_not_provisioned} do
      discover_and_repair(run, admin)
    end
  end

  defp discover_and_repair(run, admin) do
    sql =
      "SELECT COALESCE(json_agg(t), '[]'::json) FROM " <>
        "(SELECT datname AS database, pg_get_userbyid(datdba) AS username " <>
        "FROM pg_database WHERE NOT datistemplate " <>
        "AND left(datname, 4) = 'app_' " <>
        "AND left(pg_get_userbyid(datdba), 4) = 'app_' ORDER BY datname) t"

    command =
      "docker exec #{@container} psql -v ON_ERROR_STOP=1 -U #{shell_escape(admin.username)} " <>
        "-d postgres -tAc #{shell_escape(sql)}"

    case run.([command]) do
      {output, 0} ->
        with {:ok, tenants} when is_list(tenants) <- Jason.decode(String.trim(output)) do
          Enum.reduce_while(tenants, {:ok, []}, fn tenant, {:ok, repaired} ->
            credential = %{database: tenant["database"], username: tenant["username"]}

            case isolate_tenant(run, admin, credential) do
              :ok -> {:cont, {:ok, repaired ++ [credential.database]}}
              {:error, reason} -> {:halt, {:error, {credential.database, reason}}}
            end
          end)
        else
          result -> {:error, {:database_inventory_invalid, result}}
        end

      {output, status} ->
        {:error, {:database_inventory_failed, status, String.trim(output)}}
    end
  end

  @doc """
  Copy a legacy database on the same box into this environment's tenant,
  then hand ownership of everything it brought over to the tenant role.

  `source` names another container and database `:run` already reaches —
  never a remote host, since the legacy app and `cms-postgres` share a
  server. The dump and the restore are one piped command, so the data never
  touches the filesystem in between. A dump taken with `--no-owner` restores
  everything to whichever role ran `pg_restore` (the admin, here), which is
  why ownership is reassigned afterward rather than carried by the dump —
  the dump cannot know the tenant role's name.

  Row counts are compared, table by table, once the restore and the
  ownership change are both done. A mismatch is reported rather than
  silently accepted; teardown has nothing to do with an import, so nothing
  here is undone on failure.
  """
  @spec import_from(Scope.t(), String.t(), %{container: String.t(), database: String.t()}, keyword()) ::
          {:ok, %{source: map(), target: map()}} | {:error, term()}
  def import_from(%Scope{} = scope, environment, source, opts) do
    run = Keyword.fetch!(opts, :run)

    with {:ok, credential} <- serve_credential(scope, environment, opts),
         target = %{database: credential.database, username: credential.username},
         :ok <- dump_and_restore(run, source, target),
         :ok <- reassign_ownership(run, target) do
      compare_row_counts(run, source, target)
    end
  end

  @doc """
  Whether `target_database` already holds what `source` does, table by
  table. Never writes anything — `import_from/4`'s own idempotency check,
  and `:import`'s `verify/3`.
  """
  @spec imported?(keyword(), %{container: String.t(), database: String.t()}, String.t()) ::
          {:ok, boolean()} | {:error, term()}
  def imported?(opts, source, target_database) do
    run = Keyword.fetch!(opts, :run)

    with {:ok, source_counts} <-
           table_row_counts(run, source.container, @admin_username, source.database),
         {:ok, target_counts} <-
           table_row_counts(run, @container, @admin_username, target_database) do
      {:ok, source_counts == target_counts}
    end
  end

  defp compare_row_counts(run, source, target) do
    with {:ok, source_counts} <-
           table_row_counts(run, source.container, @admin_username, source.database),
         {:ok, target_counts} <-
           table_row_counts(run, @container, @admin_username, target.database) do
      if source_counts == target_counts do
        {:ok, %{source: source_counts, target: target_counts}}
      else
        {:error, {:database_import_row_counts_mismatched, source_counts, target_counts}}
      end
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
         :ok <- ensure_database(run, admin, credential),
         :ok <- isolate_tenant(run, admin, credential) do
      ensure_vector_extension(run, admin, credential)
    end
  end

  # Applied to existing databases too: PostgreSQL grants CONNECT to PUBLIC
  # at creation, independently of schema/table privileges.
  defp isolate_tenant(run, admin, credential) do
    database = sql_identifier(credential.database)
    username = sql_identifier(credential.username)

    sql =
      "REVOKE CONNECT ON DATABASE #{database} FROM PUBLIC; " <>
        "GRANT CONNECT ON DATABASE #{database} TO #{username};"

    schema_sql = "REVOKE ALL ON SCHEMA public FROM PUBLIC"

    with :ok <- run_admin_sql(run, admin, sql, :database_isolation_failed) do
      command =
        "docker exec #{@container} psql -v ON_ERROR_STOP=1 -U #{shell_escape(admin.username)} " <>
          "-d #{shell_escape(credential.database)} -c #{shell_escape(schema_sql)} > /dev/null"

      case run.([command]) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {:database_isolation_failed, status, String.trim(output)}}
      end
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

  # One piped command, both sides `docker exec`: the legacy container never
  # takes a network hop to reach `cms-postgres`, both being on the same box.
  # `--no-owner --no-acl --no-comments` on the dump side matches the hand-run
  # recipe this step automates — ownership is reassigned separately, once the
  # restored role's actual name is known.
  defp dump_and_restore(run, source, target) do
    dump =
      "docker exec #{shell_escape(source.container)} pg_dump -Fc --no-owner --no-acl " <>
        "--no-comments -U #{shell_escape(@admin_username)} -d #{shell_escape(source.database)}"

    restore =
      "docker exec -i #{@container} pg_restore --no-owner --no-acl " <>
        "-U #{shell_escape(@admin_username)} -d #{shell_escape(target.database)}"

    case run.([dump <> " | " <> restore]) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:database_import_failed, status, String.trim(output)}}
    end
  end

  # A dump restored with `--no-owner` lands on whichever role ran
  # `pg_restore` — the admin, never the tenant, which the dump cannot name.
  # Every table, sequence and view in `public` is walked rather than listed,
  # since the legacy schema is whatever the adopted app happens to have.
  defp reassign_ownership(run, target) do
    owner = sql_escape(target.username)

    sql =
      "DO $$ DECLARE r RECORD; BEGIN " <>
        "FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP " <>
        "EXECUTE format('ALTER TABLE public.%I OWNER TO %I', r.tablename, #{owner}); END LOOP; " <>
        "FOR r IN SELECT sequencename FROM pg_sequences WHERE schemaname = 'public' LOOP " <>
        "EXECUTE format('ALTER SEQUENCE public.%I OWNER TO %I', r.sequencename, #{owner}); " <>
        "END LOOP; " <>
        "FOR r IN SELECT viewname FROM pg_views WHERE schemaname = 'public' LOOP " <>
        "EXECUTE format('ALTER VIEW public.%I OWNER TO %I', r.viewname, #{owner}); END LOOP; " <>
        "END $$;"

    command =
      "docker exec #{@container} psql -v ON_ERROR_STOP=1 -U #{shell_escape(@admin_username)} " <>
        "-d #{shell_escape(target.database)} -c #{shell_escape(sql)} > /dev/null"

    case run.([command]) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:database_import_ownership_failed, status, String.trim(output)}}
    end
  end

  # One query, every base table in `public`: the dynamic-count trick
  # (`query_to_xml`/`xpath`) avoids a round trip per table, and is exact —
  # unlike `pg_stat_user_tables.n_live_tup`, which is an estimate that has not
  # caught up right after a bulk restore.
  @row_count_sql "SELECT COALESCE(json_object_agg(t.relname, t.cnt), '{}'::json) FROM " <>
                   "(SELECT c.relname, (xpath('/row/c/text()', query_to_xml(format(" <>
                   "'select count(*) as c from %I.%I', n.nspname, c.relname), false, true, " <>
                   "'')))[1]::text::bigint AS cnt FROM pg_class c JOIN pg_namespace n " <>
                   "ON n.oid = c.relnamespace WHERE c.relkind = 'r' AND n.nspname = 'public') t"

  defp table_row_counts(run, container, username, database) do
    command =
      "docker exec #{shell_escape(container)} psql -v ON_ERROR_STOP=1 " <>
        "-U #{shell_escape(username)} -d #{shell_escape(database)} -tAc #{shell_escape(@row_count_sql)}"

    case run.([command]) do
      {output, 0} ->
        case Jason.decode(String.trim(output)) do
          {:ok, counts} -> {:ok, counts}
          {:error, reason} -> {:error, {:database_row_counts_invalid, reason}}
        end

      {output, status} ->
        {:error, {:database_row_counts_failed, container, status, String.trim(output)}}
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

  # Catalog names can contain quotes; quote identifiers before building SQL.
  defp sql_identifier(value), do: "\"" <> String.replace(value, "\"", "\"\"") <> "\""

  defp sql_escape(value), do: "'" <> String.replace(value, "'", "''") <> "'"

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
