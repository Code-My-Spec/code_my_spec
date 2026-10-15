defmodule CodeMySpec.Generators.DeployBoilerplate do
  @moduledoc """
  The manifest of deploy artifacts a generated project is expected to carry,
  and the checks that decide whether each one is actually present and correct.

  The artifacts themselves are emitted by the `cms_new` generator, which lives
  in its own repository. This module is the reader: it describes what should be
  there and inspects a project to find out what is.

  Each entry carries the reason it exists. A missing Dockerfile is obvious; a
  health route inside a router pipeline, or a `force_ssl` without a health
  exclusion, both look fine to the eye and break deploys in ways that point
  nowhere near the cause.
  """

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files
  alias CodeMySpec.Users.Scope

  @type artifact :: %{
          path: String.t() | nil,
          key: atom(),
          description: String.t(),
          why: String.t()
        }

  @files [
    %{
      key: :dockerfile,
      path: "Dockerfile",
      description: "Dockerfile",
      why:
        "the image is built in CI from this; without it the first push produces nothing to deploy"
    },
    %{
      key: :ci_workflow,
      path: ".github/workflows/build.yml",
      description: "CI build workflow",
      why:
        "publishes the multi-arch image the deploy pulls by commit SHA, so what runs is traceable to a commit"
    },
    %{
      key: :deploy_prod,
      path: "config/deploy.yml",
      description: "production deploy configuration",
      why: "names production's own host and APP_ENV"
    },
    %{
      key: :deploy_uat,
      path: "config/deploy.uat.yml",
      description: "UAT deploy configuration",
      why:
        "names UAT's own host and APP_ENV; environments never share a server, so they never share a config"
    },
    %{
      key: :sops_rules,
      path: ".sops.yaml",
      description: "SOPS rules",
      why:
        "declares one age recipient per environment, so UAT's key cannot open production's secrets"
    },
    %{
      key: :boot_overlay,
      path: "rel/overlays/bin/boot",
      description: "boot release overlay",
      why:
        "the Dockerfile's CMD; decrypts the environment before starting the release, without which the app raises \"environment variable DATABASE_URL is missing\" and the deploy reports a failed traffic swap"
    },
    %{
      key: :migrate_overlay,
      path: "rel/overlays/bin/migrate",
      description: "migrate release overlay",
      why:
        "lets the deploy migrate against the new image before traffic moves to it, decrypting the same environment the app boots with"
    },
    %{
      key: :deploy_script,
      path: "bin/deploy",
      description: "deploy script",
      why:
        "the only supported deploy entry point; enforces migrate-before-swap and refuses to run on a dirty tree"
    },
    %{
      key: :backup_script,
      path: "bin/backup",
      description: "backup script",
      why:
        "dumps straight from the server to the bucket and restores from it, so a database dump never passes through the control plane"
    }
  ]

  @env_files ["envs/prod.enc.env", "envs/uat.enc.env"]

  @plaintext_env_names [".env", ".env.local", ".env.production", ".env.schema"]

  @doc """
  The expected artifacts, in the order a reader would want them reported.
  """
  @spec manifest() :: [artifact()]
  def manifest, do: @files

  @doc """
  Returns the artifacts a project is missing, each with the reason it matters.

  An empty list means the project carries everything the setup routine assumes
  it can find. Checks use the supplied environment.
  """
  @spec missing(Scope.t(), Environment.t() | nil) :: [artifact()]
  def missing(%Scope{} = scope, env) do
    Enum.reject(@files, &present?(scope, &1.path, env))
  end

  @doc """
  Returns the encrypted environment files a project is missing, using the
  supplied environment.
  """
  @spec missing_env_files(Scope.t(), Environment.t() | nil) :: [String.t()]
  def missing_env_files(%Scope{} = scope, env) do
    Enum.reject(@env_files, &present?(scope, &1, env))
  end

  @doc """
  Returns any plaintext environment files the project would actually ship or
  push.

  A file ignored by both `.gitignore` and `.dockerignore` has no exposure path
  and is not reported (projects keep a local `.env` for dev-only secrets; there
  is no `envs/dev.enc.env`). Both, not either: one alone still ships it to git
  history or the image. Checks use the supplied environment.
  """
  @spec plaintext_env_files(Scope.t(), Environment.t() | nil) :: [String.t()]
  def plaintext_env_files(%Scope{} = scope, env) do
    @plaintext_env_names
    |> Enum.filter(&present?(scope, &1, env))
    |> Enum.reject(&excluded_from_shipping?(env, &1))
  end

  # No proof of exclusion is not exclusion: no checkout, a git that cannot
  # answer or an unreadable `.dockerignore` all answer `false`. A directoryless
  # (harness-scoped) environment is checked before running `git`, so no command
  # runs without a checkout to run in.
  defp excluded_from_shipping?(nil, _path), do: false

  defp excluded_from_shipping?(%Environment{cwd: cwd}, _path)
       when not is_binary(cwd) or cwd == "",
       do: false

  defp excluded_from_shipping?(env, path) do
    git_ignores?(env, path) and docker_ignores?(env, path)
  end

  defp git_ignores?(env, path) do
    match?({_, 0}, Environments.cmd(env, "git", ["check-ignore", "-q", path]))
  end

  defp docker_ignores?(env, path) do
    case Environments.read_file(env, ".dockerignore") do
      {:ok, body} ->
        body |> String.split("\n") |> Enum.any?(&dockerignore_pattern_matches?(&1, path))

      _ ->
        false
    end
  end

  # `.dockerignore` has no `check-ignore`, so this reads its patterns: simple
  # `*` / `?` globs, which is what excluding a dotfile by name uses.
  defp dockerignore_pattern_matches?(line, path) do
    case line |> String.trim() |> String.trim_leading("/") do
      "" -> false
      "#" <> _ -> false
      pattern -> glob_match?(pattern, path)
    end
  end

  defp glob_match?(pattern, path) do
    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    Regex.match?(~r/^#{regex}$/, path)
  end

  @doc """
  Checks that `force_ssl`, where configured, excludes the health path.

  Returns `:ok` when no `force_ssl` is configured at all (nothing can redirect
  the probe) or when every occurrence excludes a health path. Otherwise returns
  the offending file.

  The proxy probes the app port over plain HTTP with no forwarded-proto
  header, so an unexcluded `force_ssl` answers 301, the proxy reads the
  container as unhealthy, and the swap never completes.
  """
  @spec force_ssl_excludes_health(Environments.Environment.t(), String.t()) ::
          :ok | {:error, {:force_ssl_without_health_exclusion, String.t()}}
  def force_ssl_excludes_health(env, config_path \\ "config/runtime.exs") do
    case Environments.read_file(env, config_path) do
      {:ok, body} -> check_force_ssl(body, config_path)
      _ -> :ok
    end
  end

  # Only a `paths:` entry excludes the health route: Plug.SSL reads a bare list
  # of strings as hosts. See knowledge/infrastructure, "Deploy readiness audit".
  @health_exclusion ~r/paths:\s*\[[^\]]*(health|up)/

  defp check_force_ssl(body, path) do
    active = active_lines(body)

    cond do
      not String.contains?(active, "force_ssl") -> :ok
      Regex.match?(@health_exclusion, active) -> :ok
      true -> {:error, {:force_ssl_without_health_exclusion, path}}
    end
  end

  # Full-line comments dropped: `phx.new` ships `force_ssl` commented out.
  # Whole lines only, since a mid-line `#` may be part of a string value.
  defp active_lines(body) do
    body
    |> String.split("\n")
    |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
    |> Enum.join("\n")
  end

  @doc """
  Checks that the health route is declared outside every router pipeline.

  A health route inside `:browser` carries session and CSRF plugs and can fail
  the proxy's probe for reasons unrelated to whether the app is up.

  When the router has no `/health` route, an `endpoint.ex` beside it that
  mentions `"/health"` satisfies it too (a plug before the router runs no
  pipeline). The fallback is deliberately loose — a textual mention — because
  an atom plug is usually implemented by a `defp` further down the module.
  """
  @spec health_route_unpiped(Environments.Environment.t(), String.t()) ::
          :ok
          | {:error, {:no_health_route, String.t()}}
          | {:error, {:health_route_piped, String.t()}}
  def health_route_unpiped(env, router_path) do
    case Environments.read_file(env, router_path) do
      {:ok, body} ->
        case check_health_route(body, router_path) do
          {:error, {:no_health_route, _}} -> endpoint_health_plug(env, router_path)
          result -> result
        end

      _ ->
        endpoint_health_plug(env, router_path)
    end
  end

  defp endpoint_health_plug(env, router_path) do
    with path when not is_nil(path) <- endpoint_path(router_path),
         {:ok, body} <- Environments.read_file(env, path),
         true <- String.contains?(body, "\"/health\"") do
      :ok
    else
      _ -> {:error, {:no_health_route, router_path}}
    end
  end

  # `router_path` is always `lib/<app>_web/router.ex`; the endpoint sits
  # beside it by the same convention.
  defp endpoint_path(router_path) do
    case String.split(router_path, "router.ex", parts: 2) do
      [prefix, ""] -> "#{prefix}endpoint.ex"
      _ -> nil
    end
  end

  @doc """
  Checks that the release module the migrate overlay calls actually exists.

  `rel/overlays/bin/migrate` runs `./bin/<app> eval <App>.Release.migrate`
  inside the released binary, where Mix is not available to run
  `mix ecto.migrate`. Without this module a project passes every other check
  and fails only at the migration step on a real box. The supplied
  environment determines where the check reads.
  """
  @spec release_module_exists?(Scope.t(), String.t() | nil, Environment.t() | nil) ::
          :ok | {:error, {:missing_release_module, String.t()}}
  def release_module_exists?(_scope, nil, _env), do: :ok

  def release_module_exists?(%Scope{} = scope, path, env) do
    if present?(scope, path, env), do: :ok, else: {:error, {:missing_release_module, path}}
  end

  defp check_health_route(body, path) do
    scopes = String.split(body, ~r/\n\s*scope /)

    case Enum.find(scopes, &Regex.match?(~r|"/health"|, &1)) do
      nil -> {:error, {:no_health_route, path}}
      scope -> pipeline_check(scope, path)
    end
  end

  defp pipeline_check(scope, path) do
    if String.contains?(scope, "pipe_through"),
      do: {:error, {:health_route_piped, path}},
      else: :ok
  end

  # Live first; the synced `Files` table is the fallback for a harness-scoped
  # caller whose environment has no working directory to check.
  # See knowledge/infrastructure, "Deploy readiness audit".
  defp present?(%Scope{} = scope, path, env) do
    Environments.file_exists?(env, path) == true or synced?(scope, path)
  end

  # Checked first: `Files.get_by_path/2` would raise on a nil project id.
  defp synced?(%Scope{active_project_id: nil}, _path), do: false

  defp synced?(scope, path) do
    case Files.get_by_path(scope, path) do
      nil -> false
      _file -> true
    end
  end
end
