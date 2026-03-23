defmodule CodeMySpec.Projects do
  @moduledoc """
  The Projects context.
  """

  import Ecto.Query, warn: false
  alias CodeMySpec.Repo

  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Users.Scope

  @doc """
  Subscribes to scoped notifications about any project changes.

  The broadcasted messages match the pattern:

    * {:created, %Project{}}
    * {:updated, %Project{}}
    * {:deleted, %Project{}}

  """
  def subscribe_projects(%Scope{} = scope) do
    key = scope.user.id

    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{key}:projects")
  end

  defp broadcast(%Scope{} = scope, message) do
    key = scope.user.id

    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, "user:#{key}:projects", message)
  end

  @doc """
  Returns the list of projects.

  ## Examples

      iex> list_projects(scope)
      [%Project{}, ...]

  """
  def list_projects(%Scope{} = scope) do
    Repo.all_by(Project, account_id: scope.active_account_id)
  end

  @doc """
  Gets a single project.

  Returns `{:ok, %Project{}}` if the project exists, `{:error, :not_found}` otherwise.

  ## Examples

      iex> get_project(scope, 123)
      {:ok, %Project{}}

      iex> get_project(scope, 456)
      {:error, :not_found}

  """
  def get_project(%Scope{} = scope, id) do
    case Repo.get_by(Project, id: id, account_id: scope.active_account_id) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  @doc """
  Gets a project by name (case-insensitive). For local web routes using project name in URL.
  """
  def get_project_by_name(name) when is_binary(name) do
    slug = name |> String.replace(~r/[-_]/, " ") |> String.downcase()

    query =
      from p in Project,
        where: fragment("lower(replace(replace(?, '-', ' '), '_', ' '))", p.name) == ^slug

    case Repo.one(query) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  @doc """
  Gets a project by its local filesystem path. For hook endpoints that
  resolve project from X-Working-Dir instead of a project name in the URL.
  """
  def get_project_by_local_path(path) when is_binary(path) do
    case Repo.get_by(Project, local_path: path) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  def get_project!(%Scope{} = scope, id) do
    Repo.get_by!(Project, id: id, account_id: scope.active_account_id)
  end

  @doc """
  Creates a project.

  ## Examples

      iex> create_project(%{field: value})
      {:ok, %Project{}}

      iex> create_project(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_project(%Scope{} = scope, attrs) do
    with {:ok, project = %Project{}} <-
           %Project{}
           |> Project.changeset(attrs, scope)
           |> Repo.insert() do
      broadcast(scope, {:created, project})
      {:ok, project}
    end
  end

  @doc """
  Updates a project.

  ## Examples

      iex> update_project(project, %{field: new_value})
      {:ok, %Project{}}

      iex> update_project(project, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_project(%Scope{} = scope, %Project{} = project, attrs) do
    true = project.account_id == scope.active_account_id

    with {:ok, project = %Project{}} <-
           project
           |> Project.changeset(attrs, scope)
           |> Repo.update() do
      broadcast(scope, {:updated, project})
      {:ok, project}
    end
  end

  @doc """
  Deletes a project.

  ## Examples

      iex> delete_project(project)
      {:ok, %Project{}}

      iex> delete_project(project)
      {:error, %Ecto.Changeset{}}

  """
  def delete_project(%Scope{} = scope, %Project{} = project) do
    true = project.account_id == scope.active_account_id

    with {:ok, project = %Project{}} <-
           Repo.delete(project) do
      broadcast(scope, {:deleted, project})
      {:ok, project}
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking project changes.

  ## Examples

      iex> change_project(project)
      %Ecto.Changeset{data: %Project{}}

  """
  def change_project(%Scope{} = scope, %Project{} = project, attrs \\ %{}) do
    true = project.account_id == scope.active_account_id

    Project.changeset(project, attrs, scope)
  end

  @doc """
  Creates a GitHub repository for the project.

  ## Parameters
  - `scope` - User scope for multi-tenant isolation and GitHub authentication
  - `project` - The project to create a repo for
  - `repo_type` - Either :code_repo or :docs_repo
  - `repo_suffix` - Suffix to append to project name (e.g., "-code", "-docs")

  ## Examples

      iex> create_github_repo(scope, project, :code_repo, "-code")
      {:ok, "https://github.com/username/my-project-code"}

      iex> create_github_repo(scope, project, :docs_repo, "-docs")
      {:ok, "https://github.com/username/my-project-docs"}

      iex> create_github_repo(scope, project, :code_repo, "-code")
      {:error, :github_not_connected}
  """
  def create_github_repo(%Scope{} = scope, %Project{} = project, repo_type, attrs, repo_suffix)
      when repo_type in [:code_repo, :docs_repo] do
    # Sanitize project name for GitHub (replace spaces with hyphens, lowercase)
    sanitized_name =
      (project.name || attrs["name"])
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-_]/, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")

    repo_name = sanitized_name <> repo_suffix

    repo_attrs = %{
      name: repo_name,
      description: project.description || "Repository for #{project.name}",
      private: true
    }

    case CodeMySpec.GitHub.create_repository(scope, repo_attrs) do
      {:ok, %{html_url: url}} ->
        {:ok, url}

      {:error, :github_not_connected} ->
        {:error, :github_not_connected}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
