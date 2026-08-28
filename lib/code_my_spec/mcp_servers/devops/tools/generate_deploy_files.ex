defmodule CodeMySpec.McpServers.Devops.Tools.GenerateDeployFiles do
  @moduledoc """
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

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Generators.DeployArtifacts
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Provisioning.Registry
  alias CodeMySpec.Resources

  schema do
  end

  @impl true
  def execute(_params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, %{}),
         {:ok, project} <- Validators.devops_project(scope) do
      scope |> generate(project) |> reply(frame)
    else
      {:error, reason} -> {:reply, error(reason), frame}
    end
  end

  defp generate(scope, project) do
    project_scope = Resources.project_scope(scope, project)

    DeployArtifacts.generate(project_scope.environment,
      app: DeployArtifacts.otp_app_name(project),
      host: project.domain || "example.com",
      owner: System.get_env("GITHUB_SPEX_OWNER") || "your-org",
      registry: Registry.default_host(),
      image: registry_image(project_scope)
    )
  end

  # The registry `:server` actually provisions, not ghcr.io — a generated
  # `image:` composed from `owner`/`app` names a path this registry never
  # served the project at, since it carries no owner segment at all.
  defp registry_image(scope) do
    case Registry.image(scope) do
      {:ok, image} -> image
      _ -> nil
    end
  end

  defp reply({:ok, []}, frame), do: {:reply, ok("Every deploy file is already in place."), frame}

  defp reply({:ok, written}, frame),
    do: {:reply, ok("Wrote #{length(written)} file(s):\n" <> Enum.map_join(written, "\n", &"  - #{&1}")), frame}

  defp reply({:error, reason}, frame), do: {:reply, error(reason), frame}

  defp ok(text), do: Response.tool() |> Response.text(text)

  defp error(reason),
    do: Response.tool() |> Response.error("Could not generate deploy files: #{inspect(reason)}")
end
