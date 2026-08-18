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
  @spec missing(Environments.Environment.t()) :: [artifact()]
  def missing(env) do
    Enum.reject(@files, &present?(env, &1.path))
  end

  @doc """
  Returns the encrypted environment files a project is missing.
  """
  @spec missing_env_files(Environments.Environment.t()) :: [String.t()]
  def missing_env_files(env) do
    Enum.reject(@env_files, &present?(env, &1))
  end

  @doc """
  Returns any plaintext environment files found in the project.

  Their presence is the failure — a generated project is meant to be safe to
  push from its first commit, and a plaintext env file is the way that stops
  being true.
  """
  @spec plaintext_env_files(Environments.Environment.t()) :: [String.t()]
  def plaintext_env_files(env) do
    Enum.filter(@plaintext_env_names, &present?(env, &1))
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
    cond do
      not String.contains?(body, "force_ssl") -> :ok
      Regex.match?(@health_exclusion, body) -> :ok
      true -> {:error, {:force_ssl_without_health_exclusion, path}}
    end
  end

  @doc """
  Checks that the health route is declared outside every router pipeline.

  A health route inside `:browser` carries session and CSRF plugs and can fail
  the proxy's probe for reasons unrelated to whether the app is up.
  """
  @spec health_route_unpiped(Environments.Environment.t(), String.t()) ::
          :ok
          | {:error, {:no_health_route, String.t()}}
          | {:error, {:health_route_piped, String.t()}}
  def health_route_unpiped(env, router_path) do
    case Environments.read_file(env, router_path) do
      {:ok, body} -> check_health_route(body, router_path)
      _ -> {:error, {:no_health_route, router_path}}
    end
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

  defp present?(env, path), do: Environments.file_exists?(env, path) == true
end
