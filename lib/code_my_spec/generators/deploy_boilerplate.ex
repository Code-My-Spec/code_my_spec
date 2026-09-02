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
      why: "the image is built in CI from this; without it the first push produces nothing to deploy"
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
      why: "declares one age recipient per environment, so UAT's key cannot open production's secrets"
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
  it can find.
  """
  @spec missing(Scope.t()) :: [artifact()]
  def missing(scope) do
    Enum.reject(@files, &present?(scope, &1.path))
  end

  @doc """
  Returns the encrypted environment files a project is missing.
  """
  @spec missing_env_files(Scope.t()) :: [String.t()]
  def missing_env_files(scope) do
    Enum.reject(@env_files, &present?(scope, &1))
  end

  @doc """
  Returns any plaintext environment files found in the project.

  Their presence is the failure — a generated project is meant to be safe to
  push from its first commit, and a plaintext env file is the way that stops
  being true.
  """
  @spec plaintext_env_files(Scope.t()) :: [String.t()]
  def plaintext_env_files(scope) do
    Enum.filter(@plaintext_env_names, &present?(scope, &1))
  end

  @doc """
  Checks that `force_ssl`, where configured, excludes the health path.

  Returns `:ok` when no `force_ssl` is configured at all (nothing can redirect
  the probe) or when every occurrence excludes a health path. Otherwise returns
  the offending file.

  This is the trap worth encoding: the proxy probes the app port directly over
  plain HTTP with no forwarded-proto header, so an unexcluded `force_ssl`
  answers with a 301, the proxy reads that as an unhealthy container, and the
  swap never completes — a deploy failing for a reason unrelated to the app.
  """
  @spec force_ssl_excludes_health(Environments.Environment.t(), String.t()) ::
          :ok | {:error, {:force_ssl_without_health_exclusion, String.t()}}
  def force_ssl_excludes_health(env, config_path \\ "config/runtime.exs") do
    case Environments.read_file(env, config_path) do
      {:ok, body} -> check_force_ssl(body, config_path)
      _ -> :ok
    end
  end

  # A `paths:` entry naming the health route, which is the only thing that
  # actually excludes it.
  #
  # This used to accept any `exclude:` list mentioning health, which passed a
  # flat `exclude: ["/health", "localhost", "127.0.0.1"]` — a form Plug.SSL
  # does not read at all. Its `:exclude` must be `[hosts: ...]`,
  # `[paths: ...]` or `[conn: ...]`; a bare list of strings excludes nothing.
  # So the check said yes, the probe still got a 301, and the deploy failed
  # with "target failed to become healthy" while this reported the config fine.
  @health_exclusion ~r/paths:\s*\[[^\]]*(health|up)/

  defp check_force_ssl(body, path) do
    active = active_lines(body)

    cond do
      not String.contains?(active, "force_ssl") -> :ok
      Regex.match?(@health_exclusion, active) -> :ok
      true -> {:error, {:force_ssl_without_health_exclusion, path}}
    end
  end

  # Full-line comments dropped before either check runs. `phx.new`'s own
  # boilerplate ships `force_ssl` commented out in exactly this shape — the
  # whole line prefixed with `#`, never enabled — and a raw substring match
  # flagged it as an active, unexcluded redirect it was never going to send.
  # Found live adopting broken_oaths: the string only ever appeared inside
  # that inert block, config/runtime.exs configures no force_ssl at all, and
  # this still refused the deploy.
  #
  # Whole lines only, not a trailing `# comment` after real code — mid-line
  # stripping risks cutting a `#` that is part of a string value (a URL
  # fragment, say) rather than a comment, and nothing about this check needs
  # that case to work.
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

  A route the router never sees at all satisfies this too: found live against
  MarketMySpec, whose `/health` is a plug in `endpoint.ex` rather than a
  router route — a stronger guarantee than an unpiped router scope, not a
  weaker one, since no pipeline exists to run before the router is even
  reached. Checked as a fallback only, so a project with a real router route
  still reports on that route's own pipeline placement first. Detection is
  deliberately loose (does `endpoint.ex` mention the path at all) rather than
  parsing plug declaration order against the function it names: a plug
  referenced by atom (`plug :health_check`) is ordinarily implemented by a
  `defp` further down the same module, so "is the path textually before the
  router plug line" would reject the exact shape it needs to accept. The
  ordering guarantee this check exists to protect stays enforced by the
  router branch above; this branch only answers "does something here appear
  to handle it."
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
  `mix ecto.migrate`. A project missing this module passes every other check,
  builds, pushes and boots — and only fails once the migration step runs
  against a real box, several steps past where the cause is visible.
  """
  @spec release_module_exists?(Scope.t(), String.t() | nil) ::
          :ok | {:error, {:missing_release_module, String.t()}}
  def release_module_exists?(_scope, nil), do: :ok

  def release_module_exists?(scope, path) do
    if present?(scope, path), do: :ok, else: {:error, {:missing_release_module, path}}
  end

  defp check_health_route(body, path) do
    scopes = String.split(body, ~r/\n\s*scope /)

    case Enum.find(scopes, &Regex.match?(~r|"/health"|, &1)) do
      nil -> {:error, {:no_health_route, path}}
      scope -> pipeline_check(scope, path)
    end
  end

  defp pipeline_check(scope, path) do
    case String.contains?(scope, "pipe_through") do
      true -> {:error, {:health_route_piped, path}}
      false -> :ok
    end
  end

  # Live first, the fast and common path: a real checkout answers this
  # itself and needs nothing else. The `Files` table is the fallback for
  # exactly one shape of caller — a harness-scoped devops tool, whose scope
  # carries no working directory to check live at all, but whose checkout
  # has been continuously syncing file existence into this table the whole
  # time regardless. Found live against MarketMySpec: `run_provisioning_step
  # step: "deploy"` reported every one of these artifacts missing — Dockerfile,
  # .sops.yaml, both encrypted envs, bin/deploy — despite all of them being
  # real, committed, and pushed, because the only thing this ever asked was a
  # directoryless environment that could never have answered honestly. It did
  # not need to ask that at all: the sync this project already runs had the
  # answer the whole time.
  defp present?(%Scope{environment: env} = scope, path) do
    Environments.file_exists?(env, path) == true or synced?(scope, path)
  end

  # No project to ask the sync table about — `Files.get_by_path/2` refuses
  # to build `project_id == NULL` at all (Ecto raises rather than silently
  # matching nothing on an unsafe nil comparison), so this is checked here
  # first rather than let through to become a crash. A scope with no project
  # cannot fall back to anything better than the live check already gave.
  defp synced?(%Scope{active_project_id: nil}, _path), do: false

  defp synced?(scope, path) do
    case Files.get_by_path(scope, path) do
      nil -> false
      _file -> true
    end
  end
end
