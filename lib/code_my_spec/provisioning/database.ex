defmodule CodeMySpec.Provisioning.Database do
  @moduledoc """
  The database each environment's app talks to.

  Nothing provisioned one before. `backups` ran `pg_dump` against a database
  that did not exist, the generated `config/deploy*.yml` put the app on a
  `db_net` network with nothing else on it, and the first deploy to reach
  kamal would have started a container that could not boot. A whole step was
  assumed everywhere and implemented nowhere.

  ## On the app's own box, one per environment

  Same shape as the registry, for the same reasons. UAT and production must not
  share a database — a migration tested against one would already have run
  against the other — and a container beside the app on `db_net` is what the
  generated kamal config already expects, so the app reaches it by container
  name rather than by address.

  That is deliberately the simplest thing that works, and the least durable.
  It is right for UAT and arguable for production; a managed instance is a
  different conversation, and `backups` was written as though we own the dump.

  ## The URL is a secret, and lives where the others do

  The password is generated once into `ProjectSecrets` and the connection URL
  is written into that environment's encrypted env, so the app reads it the
  same way it reads everything else. Nothing puts it in the working tree.
  """

  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.Wait
  alias CodeMySpec.Users.Scope

  @container "cms-postgres"
  @network "db_net"
  @volume "cms-postgres-data"
  @username "app"
  @port 5432

  # Pinned rather than `:latest`, because a database that silently changes
  # major version between two runs of setup is a data-loss event with a
  # convenient explanation.
  @image "postgres:17"

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
  separation the age keys have, and for the same reason.
  """
  @spec credential(Scope.t(), String.t()) ::
          {:ok, %{username: String.t(), password: String.t(), database: String.t()}}
          | {:error, term()}
  def credential(%Scope{} = scope, environment) do
    name = "database_password_#{environment}"

    case ProjectSecrets.fetch_value(scope, name) do
      {:ok, password} when is_binary(password) and password != "" ->
        {:ok, describe(password, environment)}

      _ ->
        password = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

        with {:ok, _} <- ProjectSecrets.put_value(scope, name, password) do
          {:ok, describe(password, environment)}
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
  Start this environment's database on its box.

  Idempotent: the container is replaced rather than added to, and the volume
  outlives it — which is the point of naming the volume rather than letting
  docker generate one. Re-running setup must not be a way to lose data.

  `:run` takes the command and returns `{output, status}`, so what we ask the
  box to do is assertable without a box.
  """
  @spec serve(Scope.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def serve(%Scope{} = scope, environment, opts \\ []) do
    run = Keyword.fetch!(opts, :run)

    with {:ok, credential} <- serve_credential(scope, environment, opts) do
      case run.([serve_command(credential, opts)]) do
        {_output, 0} ->
          await(run, credential, Keyword.get(opts, :database_attempts, 30))

        {output, status} ->
          {:error, {:database_start_failed, status, String.trim(output)}}
      end
    end
  end

  defp serve_credential(scope, environment, opts) do
    case Keyword.get(opts, :database_credential) do
      %{username: _, password: _, database: _} = credential -> {:ok, credential}
      _ -> credential(scope, environment)
    end
  end

  # Bound to the docker network only — never published to a host port. The
  # firewall would refuse it from outside anyway, and a database that is not
  # listening on an address is a database that cannot be reached by mistake.
  defp serve_command(credential, opts) do
    image = Keyword.get(opts, :database_image, @image)

    env =
      [
        {"POSTGRES_USER", credential.username},
        {"POSTGRES_PASSWORD", credential.password},
        {"POSTGRES_DB", credential.database}
      ]
      |> Enum.map_join(" ", fn {name, value} -> "-e #{name}=#{shell_escape(value)}" end)

    "docker network create #{@network} >/dev/null 2>&1; " <>
      "docker rm -f #{@container} >/dev/null 2>&1; " <>
      "docker run -d --name #{@container} --restart always " <>
      "--network #{@network} " <>
      "-v #{@volume}:/var/lib/postgresql/data " <>
      "#{env} #{image}"
  end

  # `docker run -d` returning 0 means the container was created. Postgres takes
  # seconds more to accept connections, and a migration that arrives first
  # fails in a way that reads like a broken image rather than an impatient
  # caller — the same distinction the registry's probe draws.
  defp await(run, credential, attempts) do
    check =
      "docker exec #{@container} pg_isready -U #{shell_escape(credential.username)} " <>
        "-d #{shell_escape(credential.database)} > /dev/null"

    case run.([check]) do
      {_output, 0} ->
        {:ok, %{host: @container, port: @port, database: credential.database}}

      _ when attempts > 1 ->
        Wait.sleep(2_000)
        await(run, credential, attempts - 1)

      _ ->
        {logs, _} = run.(["docker logs --tail 50 #{@container} 2>&1"])
        {:error, {:database_not_ready, @container, String.trim(logs)}}
    end
  end

  defp describe(password, environment) do
    %{username: @username, password: password, database: "app_#{environment}"}
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
