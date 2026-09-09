defmodule CodeMySpec.Host do
  @moduledoc """
  Many Phoenix releases on one box, isolated from each other.

  Story 986. Caddy is the only public process, each app gets a systemd unit
  and a port, one Postgres holds a database and role per app, and secrets are
  SOPS + age with a key per app. No Docker on the box, no orchestrator.

  ## One behaviour, two backends

  The behaviour is defined once — in `priv/host/provision_app.sh` and
  `priv/host/verify_isolation.sh` — and runs wherever the scope's environment
  points. In development that is a container; in production it is a Hetzner
  box. Nothing here branches on which.

  That falls out of `Environments.Container` rather than being arranged: the
  container environment drives `docker`, and `DOCKER_HOST` already accepts
  `ssh://user@host`. So "dev or prod" is configuration, not a second transport
  to write and debug — and the scripts that get rehearsed in a drill are
  byte-for-byte the ones that run on the box.

  Shell scripts rather than Elixir doing the work, deliberately. Every step is
  `adduser`, `psql`, `age-keygen`, `systemctl` — reimplementing that in Elixir
  would buy a worse version of a thing the box already does, and would mean
  the runbook and the code could drift. A human can run these by hand at three
  in the morning, which is the situation they exist for.

  ## Isolation is the acceptance criterion

  Not the provisioning. Every one of the three properties defaults to *open*:

    * Postgres grants `CONNECT` to `PUBLIC` on every new database
    * a key file is readable by anyone who can traverse to it
    * all apps share one epmd, and a known cookie is `:erpc` — arbitrary code
      execution as that user

  So `verify_isolation/3` asserts three failures, and the drill
  (`priv/host/drill.sh`) breaches each one to confirm the check catches it.
  Three checks that pass on a correct box prove nothing until you have watched
  them fail on a broken one.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Environments, CodeMySpec.Users],
    exports: :all

  require Logger

  alias CodeMySpec.Environments
  alias CodeMySpec.Users.Scope

  @scripts_dir "priv/host"

  @type app :: %{name: String.t(), port: pos_integer(), domain: String.t() | nil}

  @doc """
  Provision one app: user, key, secrets, database, unit, ingress.

  Idempotent — safe to re-run after a partial failure, which is the run most
  likely to have one.

  `ADMIN_AGE_PUBKEY` is required rather than defaulted. Secrets are encrypted
  to the app's key *and* the admin's, and a default here would silently
  produce a box whose secrets nobody can read once the box is gone.
  """
  @spec provision_app(Scope.t(), app(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def provision_app(%Scope{} = scope, %{name: name, port: port} = app, opts \\ []) do
    admin_key = Keyword.get(opts, :admin_age_pubkey) || System.get_env("ADMIN_AGE_PUBKEY")

    if is_nil(admin_key) or admin_key == "" do
      {:error,
       "no admin age key — secrets must be encrypted to the admin key as well as the app's, " <>
         "or losing the box loses the ability to read or rotate them"}
    else
      args = [name, to_string(port)] ++ List.wrap(app[:domain])

      run_opts = [env: [{"ADMIN_AGE_PUBKEY", admin_key}]] ++ Keyword.take(opts, [:cmd])

      scope
      |> run("provision_app.sh", args, run_opts)
      |> case do
        {output, 0} -> {:ok, output}
        {output, status} -> {:error, "provisioning #{name} failed (exit #{status}): #{output}"}
      end
    end
  end

  @doc """
  Prove `app` cannot reach `other`.

  Returns `{:ok, report}` only when every check failed as it should. The
  non-zero exit is deliberate: this is meant to gate a deploy rather than be
  read by a human who may or may not be looking.
  """
  @spec verify_isolation(Scope.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def verify_isolation(%Scope{} = scope, app, other, opts \\ []) do
    case run(scope, "verify_isolation.sh", [app, other], Keyword.take(opts, [:cmd])) do
      {output, 0} ->
        {:ok, output}

      {output, _status} ->
        Logger.error("[Host] isolation check failed between #{app} and #{other}")
        {:error, output}
    end
  end

  @doc """
  Copy the scripts onto the target.

  They live in this repository so that one edit changes what runs everywhere,
  rather than each box carrying a copy that drifts.
  """
  @spec install(Scope.t()) :: :ok | {:error, term()}
  def install(%Scope{environment: env}) when not is_nil(env) do
    for file <-
          ~w(provision_app.sh verify_isolation.sh templates/app.service templates/caddy-site) do
      source = Path.join([Application.app_dir(:code_my_spec), @scripts_dir, file])
      :ok = Environments.write_file(env, Path.join("/host", file), File.read!(source))
    end

    Environments.cmd(env, "chmod", ["+x", "/host/provision_app.sh", "/host/verify_isolation.sh"])
    :ok
  end

  def install(_scope), do: {:error, :no_environment}

  defp run(%Scope{environment: nil}, script, _args, _opts) do
    {"cannot run #{script}: this scope has no environment to run commands in", 1}
  end

  defp run(%Scope{environment: env}, script, args, opts) do
    # `:cmd` is a seam for tests to observe the command without a container;
    # in every real path it is `Environments.cmd/4`, which is what actually
    # reaches the box.
    {runner, opts} = Keyword.pop(opts, :cmd, &Environments.cmd/4)
    runner.(env, Path.join("/host", script), args, opts ++ [stderr_to_stdout: true])
  end
end
