defmodule CodeMySpec.McpServers.Devops.Tools.AdoptRepository do
  @moduledoc """
  Adopt an existing GitHub repository as a project's remote, by its real name.

  `run_devops_setup`'s repository step derives the name it looks for from the
  project's own display name — lowercase, non-alphanumeric runs collapsed to
  a single dash — and only reaches the adopt-vs-create decision once a repo
  of that exact derived name is found. A real repo named any other way
  (underscores, or a different word entirely) is a lookup miss, not a
  collision: setup would silently create a second, empty, unrelated
  repository and push the current working tree into it, never considering
  the real one.

  This runs the same repository step by the repository's own real name
  instead of a guessed one, so it reaches the real repo directly and adopts
  it — same push-and-prove behavior `run_devops_setup` would otherwise do,
  just aimed correctly.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Projects
  alias CodeMySpec.Provisioning
  alias CodeMySpec.Resources

  schema do
    field :project_id, :string, required: true, doc: "Adopt the repository for this project."

    field :repository_name, :string,
      required: true,
      doc: "The GitHub repository's exact name, e.g. \"market_my_spec\" — not a guess."
  end

  @impl true
  def execute(%{project_id: project_id, repository_name: repository_name} = params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, project} <- find_project(scope, project_id) do
      :ok =
        scope
        |> Resources.project_scope(project)
        |> Provisioning.run_step_async(:repository, adopt: true, name: repository_name)

      {:reply,
       ok(
         "Adopting #{repository_name} for #{project.name}. Call devops_status shortly to watch it converge."
       ), frame}
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

  defp ok(text), do: Response.tool() |> Response.text(text)

  defp error(reason),
    do: Response.tool() |> Response.error("Could not adopt the repository: #{inspect(reason)}")
end
