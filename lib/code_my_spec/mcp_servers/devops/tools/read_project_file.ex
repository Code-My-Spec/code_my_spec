defmodule CodeMySpec.McpServers.Devops.Tools.ReadProjectFile do
  @moduledoc """
  Read a file from a project's own checkout.

  Read-only counterpart to `generate_deploy_files`. `devops_status`'s audit can
  say a file is misconfigured (`force_ssl` without a health exclusion, say) but
  never shows the content — and `DeployArtifacts.generate/2` deliberately never
  overwrites a file that already exists, so a misconfigured (as opposed to
  missing) artifact has no automated fix. Seeing the real content is the step
  before deciding how to fix it by hand.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Projects
  alias CodeMySpec.Resources

  schema do
    field :project_id, :string, required: true, doc: "Read from this project's checkout."
    field :path, :string, required: true, doc: "Path relative to the project root."
  end

  @impl true
  def execute(%{project_id: project_id, path: path} = params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, project} <- find_project(scope, project_id) do
      scope
      |> Resources.project_scope(project)
      |> Map.fetch!(:environment)
      |> Environments.read_file(path)
      |> reply(path, frame)
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

  defp reply({:ok, content}, _path, frame), do: {:reply, ok(content), frame}
  defp reply({:error, :enoent}, path, frame), do: {:reply, error("#{path}: not found"), frame}
  defp reply({:error, reason}, _path, frame), do: {:reply, error(reason), frame}

  defp ok(content), do: Response.tool() |> Response.text(content)

  defp error(reason),
    do: Response.tool() |> Response.error("Could not read the file: #{inspect(reason)}")
end
