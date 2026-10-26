defmodule CodeMySpec.Provisioning.Tools.GenerateDeployFiles do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Generators.DeployArtifacts
  alias CodeMySpec.LocalScope
  alias CodeMySpec.Provisioning.{Registry, Steps}
  alias CodeMySpec.Resources
  alias CodeMySpec.WorkingCopies

  @impl true
  def name, do: "generate_deploy_files"

  @impl true
  def description do
    """
    Write the deploy artifacts a project is missing, onto its own checkout.

    The same write `ProvisioningLive`'s "Generate deploy files" button performs
    — `DeployArtifacts.generate/2`, which never overwrites a file already there.
    Exists as its own tool, not folded into `run_devops_setup`, because it is not
    an ordered step: nothing in the sequence runs it, `devops_status`'s
    deploy-readiness audit only reads what it should have produced, and an agent
    that has just read "missing lib/<app>/release.ex" from that audit needs a way
    to put it there without a browser.

    Writes onto the checkout of whichever project this call is connected to —
    no `project_id` parameter, so there is nothing for a caller to name (or
    mis-name) a different project's tree with.
    """
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, project} <- CodeMySpec.Tools.connected_project(scope) do
      scope |> generate(project) |> reply(context)
    else
      {:error, reason} -> error(reason)
    end
  end

  defp generate(scope, project) do
    project_scope = Resources.project_scope(scope, project)
    environment = project_environment(project_scope, project)

    prod_registry = registry_address(project_scope, "prod") || Registry.default_host()

    DeployArtifacts.generate(environment,
      app: DeployArtifacts.otp_app_name(project),
      host: project.domain || "example.com",
      owner: System.get_env("GITHUB_SPEX_OWNER") || "your-org",
      registry: prod_registry,
      image: registry_image(project_scope, prod_registry),
      kamal_image: registry_repository(project_scope),
      prod_registry: prod_registry,
      uat_registry: registry_address(project_scope, "uat")
    )
  end

  defp project_environment(%{active_working_copy_id: copy_id} = scope, _project)
       when is_binary(copy_id),
       do: WorkingCopies.execution_context(scope)

  defp project_environment(_scope, project), do: LocalScope.execution_context(project)

  # The registry `:server` actually provisions, not ghcr.io — a generated
  # `image:` composed from `owner`/`app` names a path this registry never
  # served the project at, since it carries no owner segment at all.
  defp registry_image(scope, registry_host) do
    case Registry.image(scope, registry_host: registry_host) do
      {:ok, image} -> image
      _ -> nil
    end
  end

  # Kamal wants `image:` bare, with no host — it reads the host from
  # `registry:server` separately and combines the two itself. Confirmed
  # against real kamal (`deploy_artifacts_test.exs`) and against a real,
  # already-deployed config on a shared box: a host baked into `image:` as
  # well as `registry:server` doubles up into a repository path nothing
  # actually serves.
  defp registry_repository(scope) do
    case Registry.repository(scope) do
      {:ok, repository} -> repository
      _ -> nil
    end
  end

  # Per environment, never one project-wide value — two environments on
  # two different boxes have two different registry addresses, and
  # `Registry.default_host/0` ("localhost:5000") is only ever right for a
  # registry bound to loopback, which is not true of a shared box's
  # container today. `nil` on `:not_provisioned` (no linked server yet, or
  # a linked server with no private network yet) lets `DeployArtifacts`
  # fall back to its own `:registry` default instead of baking in an
  # address nothing answers on.
  defp registry_address(scope, environment) do
    case Steps.registry_address(scope, environment) do
      {:ok, address} -> address
      _ -> nil
    end
  end

  defp reply({:ok, []}, _context), do: ok("Every deploy file is already in place.")

  defp reply({:ok, written}, _context),
    do: ok("Wrote #{length(written)} file(s):\n" <> Enum.map_join(written, "\n", &"  - #{&1}"))

  defp reply({:error, reason}, _context), do: error(reason)

  defp ok(text), do: {:ok, text}

  defp error(reason),
    do: {:error, "Could not generate deploy files: #{inspect(reason)}"}
end
