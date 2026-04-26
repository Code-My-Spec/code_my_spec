defmodule CodeMySpec.Configurations do
  @moduledoc """
  Public API for local project configuration.

  One ProjectConfiguration per project. Auto-creates with defaults on first
  access — the engineer never has to visit the config screen to get the
  standard behavior.

  Local-only: not synced to the server.
  """

  use Boundary, deps: [CodeMySpec, CodeMySpec.Repo], exports: :all

  alias CodeMySpec.Configurations.ProjectConfiguration
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @doc """
  Get the configuration for the active project, creating with defaults if missing.
  """
  @spec get_or_create(Scope.t()) :: ProjectConfiguration.t()
  def get_or_create(%Scope{active_project_id: project_id}) when not is_nil(project_id) do
    case Repo.get_by(ProjectConfiguration, project_id: project_id) do
      nil ->
        %ProjectConfiguration{}
        |> ProjectConfiguration.changeset(%{project_id: project_id})
        |> Repo.insert!()

      config ->
        config
    end
  end

  @doc """
  Update the active project's configuration.
  """
  @spec update(Scope.t(), map()) ::
          {:ok, ProjectConfiguration.t()} | {:error, Ecto.Changeset.t()}
  def update(%Scope{active_project_id: project_id} = scope, attrs)
      when not is_nil(project_id) do
    scope
    |> get_or_create()
    |> ProjectConfiguration.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Build a changeset for form rendering.
  """
  @spec change(ProjectConfiguration.t(), map()) :: Ecto.Changeset.t()
  def change(%ProjectConfiguration{} = configuration, attrs \\ %{}) do
    ProjectConfiguration.changeset(configuration, attrs)
  end
end
