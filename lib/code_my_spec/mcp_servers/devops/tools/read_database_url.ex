defmodule CodeMySpec.McpServers.Devops.Tools.ReadDatabaseUrl do
  @moduledoc """
  The connection string `:server` already minted for this environment's
  database.

  `Database.serve/3` mints and stores this project's role/database
  credential in `ProjectSecrets` the moment it provisions the container and
  tenant — before the step ever reaches the part that writes it into
  `envs/*.enc.env`, which is real local-filesystem work a project with no
  checkout on this side cannot complete (the same wall `:repository` hits).
  This is the read half of that gap: the credential already exists, and a
  caller with a real checkout elsewhere needs the value itself to encrypt it
  there, rather than this server minting it a second time somewhere it
  cannot commit anything.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Projects
  alias CodeMySpec.Provisioning.Database
  alias CodeMySpec.Resources

  schema do
    field :project_id, :string, required: true, doc: "Read the URL for this project."

    field :environment, :string,
      required: true,
      doc: "Environment name, e.g. \"prod\" or \"uat\"."
  end

  @impl true
  def execute(%{project_id: project_id, environment: environment} = params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, project} <- find_project(scope, project_id) do
      scope
      |> Resources.project_scope(project)
      |> Database.credential(environment)
      |> reply(frame)
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

  defp reply({:ok, credential}, frame), do: {:reply, ok(Database.url(credential)), frame}
  defp reply({:error, reason}, frame), do: {:reply, error(reason), frame}

  defp ok(text), do: Response.tool() |> Response.text(text)

  defp error(reason),
    do: Response.tool() |> Response.error("Could not read the database URL: #{inspect(reason)}")
end
