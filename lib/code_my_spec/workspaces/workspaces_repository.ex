defmodule CodeMySpec.Workspaces.WorkspacesRepository do
  @moduledoc "Data access for workspaces. One per project."

  import Ecto.Query, warn: false

  alias CodeMySpec.Repo
  alias CodeMySpec.Workspaces.Workspace

  @spec get(Ecto.UUID.t()) :: Workspace.t() | nil
  def get(id), do: Repo.get(Workspace, id)

  @spec get_by_project(Ecto.UUID.t()) :: Workspace.t() | nil
  def get_by_project(project_id), do: Repo.get_by(Workspace, project_id: project_id)

  @spec upsert_booting(Workspace.t() | nil, map()) ::
          {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def upsert_booting(nil, attrs), do: insert_booting(%Workspace{}, attrs)
  def upsert_booting(%Workspace{} = workspace, attrs), do: insert_booting(workspace, attrs)

  defp insert_booting(%Workspace{id: nil} = workspace, attrs) do
    workspace |> Workspace.booting_changeset(attrs) |> Repo.insert()
  end

  defp insert_booting(%Workspace{} = workspace, attrs) do
    workspace |> Workspace.booting_changeset(attrs) |> Repo.update()
  end

  @spec update(Ecto.Changeset.t()) :: {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def update(%Ecto.Changeset{} = changeset), do: Repo.update(changeset)
end
