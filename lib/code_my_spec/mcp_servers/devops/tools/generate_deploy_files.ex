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

  Requires `project_id`, unlike `run_devops_setup`'s "omit for all" — this
  writes to a specific checkout, and guessing which one a bare call meant risks
  writing into the wrong project's tree.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Generators.DeployArtifacts
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Projects
  alias CodeMySpec.Resources

  schema do
    field :project_id, :string, required: true, doc: "Write onto this project's checkout."
  end

  @impl true
  def execute(%{project_id: project_id} = params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, project} <- find_project(scope, project_id) do
      scope |> generate(project) |> reply(frame)
    else
      {:error, reason} -> {:reply, error(reason), frame}
    end
  end

  defp find_project(scope, project_id) do
    case Enum.find(Projects.list_projects(scope), &(&1.id == project_id)) do
      nil -> {:error, "no project #{project_id} on this account"}
      project -> {:ok, project}
    end
  end

  defp generate(scope, project) do
    project_scope = Resources.project_scope(scope, project)

    DeployArtifacts.generate(project_scope.environment,
      app: DeployArtifacts.otp_app_name(project),
      host: project.domain || "example.com",
      owner: System.get_env("GITHUB_SPEX_OWNER") || "your-org"
    )
  end

  defp reply({:ok, []}, frame), do: {:reply, ok("Every deploy file is already in place."), frame}

  defp reply({:ok, written}, frame),
    do: {:reply, ok("Wrote #{length(written)} file(s):\n" <> Enum.map_join(written, "\n", &"  - #{&1}")), frame}

  defp reply({:error, reason}, frame), do: {:reply, error(reason), frame}

  defp ok(text), do: Response.tool() |> Response.text(text)

  defp error(reason),
    do: Response.tool() |> Response.error("Could not generate deploy files: #{inspect(reason)}")
end
