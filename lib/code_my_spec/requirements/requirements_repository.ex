defmodule CodeMySpec.Requirements.RequirementsRepository do
  @moduledoc """
  Database operations for requirements across components, stories, and projects.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @doc """
  Clears all requirements for the entire project.
  """
  @spec clear_all_project_requirements(Scope.t()) :: {integer(), nil}
  def clear_all_project_requirements(%Scope{active_project_id: project_id}) do
    component_ids =
      Component
      |> where([c], c.project_id == ^project_id)
      |> select([c], c.id)

    # Clear component requirements
    Requirement
    |> where([r], r.component_id in subquery(component_ids))
    |> Repo.delete_all()

    # Clear story requirements for stories in this project
    story_ids =
      Story
      |> where([s], s.project_id == ^project_id)
      |> select([s], s.id)

    Requirement
    |> where([r], r.story_id in subquery(story_ids))
    |> Repo.delete_all()

    # Clear project-level requirements
    Requirement
    |> where([r], r.project_id == ^project_id)
    |> Repo.delete_all()
  end

  @spec create_requirement(Scope.t(), Component.t(), Requirement.requirement_attrs(), keyword()) ::
          {:ok, Requirement.t()} | {:error, Ecto.Changeset.t()}
  def create_requirement(%Scope{}, %Component{} = component, attrs, opts \\ []) do
    changeset =
      %Requirement{}
      |> Requirement.changeset(attrs)
      |> Ecto.Changeset.put_assoc(:component, component)

    persist_or_apply(changeset, opts, :requirements_component_id_name_index)
  end

  @spec create_story_requirement(
          Scope.t(),
          Story.t(),
          Requirement.requirement_attrs(),
          keyword()
        ) :: {:ok, Requirement.t()} | {:error, Ecto.Changeset.t()}
  def create_story_requirement(%Scope{}, %Story{} = story, attrs, opts \\ []) do
    changeset =
      %Requirement{}
      |> Requirement.changeset(Map.put(attrs, :story_id, story.id))

    persist_or_apply(changeset, opts, :requirements_story_id_name_index)
  end

  @spec create_project_requirement(
          Scope.t(),
          Project.t(),
          Requirement.requirement_attrs(),
          keyword()
        ) :: {:ok, Requirement.t()} | {:error, Ecto.Changeset.t()}
  def create_project_requirement(%Scope{}, %Project{} = project, attrs, opts \\ []) do
    changeset =
      %Requirement{}
      |> Requirement.changeset(Map.put(attrs, :project_id, project.id))

    persist_or_apply(changeset, opts, :requirements_project_id_name_index)
  end

  @spec update_requirement(Scope.t(), Requirement.t(), Requirement.requirement_attrs()) ::
          {:ok, Requirement.t()} | {:error, Ecto.Changeset.t()}
  def update_requirement(%Scope{}, %Requirement{} = requirement, attrs) do
    requirement
    |> Requirement.update_changeset(attrs)
    |> Repo.update()
  end

  @spec clear_requirements(Scope.t(), Component.t(), list()) :: Component.t()
  def clear_requirements(%Scope{}, %Component{} = component, opts) do
    if Keyword.get(opts, :persist, false) do
      Requirement
      |> where([r], r.component_id == ^component.id)
      |> Repo.delete_all()
    end

    component
    |> Map.put(:outgoing_dependencies, [])
    |> Map.put(:incoming_dependencies, [])
  end

  @spec clear_story_requirements(Scope.t(), Story.t(), keyword()) :: Story.t()
  def clear_story_requirements(%Scope{}, %Story{} = story, opts) do
    if Keyword.get(opts, :persist, false) do
      Requirement
      |> where([r], r.story_id == ^story.id)
      |> Repo.delete_all()
    end

    story
  end

  @spec clear_project_requirements(Scope.t(), Project.t(), keyword()) :: Project.t()
  def clear_project_requirements(%Scope{}, %Project{} = project, opts) do
    if Keyword.get(opts, :persist, false) do
      Requirement
      |> where([r], r.project_id == ^project.id)
      |> Repo.delete_all()
    end

    project
  end

  @upsert_fields [
    :artifact_type,
    :description,
    :checker_module,
    :satisfied_by,
    :scope,
    :satisfied,
    :score,
    :checked_at,
    :details
  ]

  # Partial unique indexes require the WHERE clause for SQLite to match them.
  @conflict_fragments %{
    requirements_component_id_name_index:
      ~s|("component_id","name") WHERE "component_id" IS NOT NULL|,
    requirements_story_id_name_index:
      ~s|("story_id","name") WHERE "story_id" IS NOT NULL|,
    requirements_project_id_name_index:
      ~s|("project_id","name") WHERE "project_id" IS NOT NULL|
  }

  defp persist_or_apply(changeset, opts, conflict_target) do
    if Keyword.get(opts, :persist, true) do
      fragment = Map.fetch!(@conflict_fragments, conflict_target)

      Repo.insert(changeset,
        on_conflict: {:replace, @upsert_fields},
        conflict_target: {:unsafe_fragment, fragment},
        returning: true
      )
    else
      Ecto.Changeset.apply_action(changeset, :insert)
    end
  end
end
