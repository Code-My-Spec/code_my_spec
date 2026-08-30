defmodule CodeMySpec.Generators do
  @moduledoc """
  Context for the deploy boilerplate a generated project ships with.

  ## What this owns, and what it does not

  The boilerplate itself — Dockerfile, CI workflow, per-environment deploy
  configs, SOPS scaffolding, the migrate overlay, `bin/deploy`, and the health
  route outside every router pipeline — is emitted by the `cms_new` generator,
  which lives in its own repository. Nothing here writes those files.

  What lives here is the reader. Story 970's premise is that a generated
  project arrives deployable so the setup routine *fills in values and runs
  commands* rather than generating build tooling. A routine that assumes those
  files exist needs a way to find out whether they actually do, and to say
  precisely what is missing when they do not — otherwise the first symptom is a
  deploy that fails several steps later for a reason pointing nowhere near the
  cause.

  So: `cms_new` writes, this verifies, `Provisioning` consumes the verdict.

  ## Why the checks are not just file-existence

  Two of them inspect content, because the failure modes they guard look
  correct from the outside:

  - a health route declared *inside* a router pipeline carries session and CSRF
    plugs, and can fail the proxy's probe for reasons unrelated to the app
  - `force_ssl` without a health exclusion answers the proxy's plain-HTTP probe
    with a 301, which the proxy reads as an unhealthy container, so the traffic
    swap never completes

  Both produce a project that looks fine in the editor and cannot deploy.
  """

  alias CodeMySpec.Environments
  alias CodeMySpec.Generators.DeployBoilerplate
  alias CodeMySpec.Users.Scope

  @type finding ::
          {:missing_file, map()}
          | {:missing_env_file, String.t()}
          | {:plaintext_env_file, String.t()}
          | {:force_ssl_without_health_exclusion, String.t()}
          | {:no_health_route, String.t()}
          | {:health_route_piped, String.t()}
          | {:missing_release_module, String.t()}

  @doc """
  Whether a project carries everything a deploy needs.

  ## Examples

      iex> deploy_ready?(scope, "lib/my_app_web/router.ex")
      true
  """
  @spec deploy_ready?(Scope.t(), String.t()) :: boolean()
  def deploy_ready?(%Scope{} = scope, router_path) do
    audit(scope, router_path) == []
  end

  @doc """
  Everything the project is missing or has configured in a way that will not
  deploy, in reporting order.

  Returns `[]` for a project the setup routine can proceed against.

  ## Examples

      iex> audit(scope, "lib/my_app_web/router.ex")
      [{:missing_file, %{key: :dockerfile, ...}}]
  """
  @spec audit(Scope.t(), String.t()) :: [finding()]
  def audit(%Scope{environment: env} = scope, router_path) when not is_nil(env) do
    missing_files(scope) ++
      missing_env_files(scope) ++
      plaintext_env_files(scope) ++
      config_findings(scope, router_path)
  end

  @doc """
  A human-readable explanation of an audit finding, including why the artifact
  matters. Used when reporting a blocked setup step back to the user.
  """
  @spec explain(finding()) :: String.t()
  def explain({:missing_file, artifact}),
    do: "missing #{artifact.description} (#{artifact.path}) — #{artifact.why}"

  def explain({:missing_env_file, path}),
    do:
      "missing encrypted environment file #{path} — secrets are committed encrypted, one file per environment"

  def explain({:plaintext_env_file, path}),
    do:
      "plaintext environment file #{path} is present — a generated project must be safe to push from its first commit"

  def explain({:force_ssl_without_health_exclusion, path}),
    do:
      "#{path} sets force_ssl without excluding the health path — the proxy's plain-HTTP probe would be redirected and the traffic swap would never complete"

  def explain({:no_health_route, path}),
    do: "#{path} declares no health route — the proxy gates the traffic swap on it"

  def explain({:health_route_piped, path}),
    do:
      "#{path} declares the health route inside a pipeline — session and CSRF plugs can fail the proxy's probe for reasons unrelated to the app"

  def explain({:missing_release_module, path}),
    do:
      "missing #{path} — the migrate overlay calls <App>.Release.migrate inside the released binary, and without this module the migration crashes on a real box instead of failing setup here"

  defp missing_files(scope) do
    scope |> DeployBoilerplate.missing() |> Enum.map(&{:missing_file, &1})
  end

  defp missing_env_files(scope) do
    scope |> DeployBoilerplate.missing_env_files() |> Enum.map(&{:missing_env_file, &1})
  end

  defp plaintext_env_files(scope) do
    scope |> DeployBoilerplate.plaintext_env_files() |> Enum.map(&{:plaintext_env_file, &1})
  end

  # The two content checks still take the environment alone, not the scope —
  # what a file *contains* is not something the `Files` sync table records
  # (path, role, mtime, size, fingerprint; never a body), so there is no
  # fallback for these the way `present?/2` has one. A harness-scoped caller
  # genuinely cannot answer them, and each already says so in its own words
  # rather than guessing.
  defp config_findings(%Scope{environment: env} = scope, router_path) do
    [
      DeployBoilerplate.force_ssl_excludes_health(env),
      DeployBoilerplate.health_route_unpiped(env, router_path),
      DeployBoilerplate.release_module_exists?(scope, release_module_path(router_path))
    ]
    |> Enum.flat_map(fn
      :ok -> []
      {:error, finding} -> [finding]
    end)
  end

  # `router_path` is always `lib/<app>_web/router.ex`, by the same convention
  # `DeployArtifacts.router/1` writes it and every caller here builds it — so
  # the release module's path is derivable rather than a second argument every
  # caller of `audit/2` would need to thread through.
  defp release_module_path(router_path) do
    case String.split(router_path, "_web/router.ex", parts: 2) do
      [app_dir, ""] -> "#{app_dir}/release.ex"
      _ -> nil
    end
  end

  @doc """
  Convenience for callers that hold an environment rather than a scope.
  """
  @spec audit_environment(Environments.Environment.t(), String.t()) :: [finding()]
  def audit_environment(env, router_path) do
    audit(%Scope{environment: env}, router_path)
  end
end
