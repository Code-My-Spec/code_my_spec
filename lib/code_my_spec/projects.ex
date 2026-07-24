defmodule CodeMySpec.Projects do
  @moduledoc """
  The Projects context.
  """

  import Ecto.Query, warn: false
  alias CodeMySpec.Oauth.Application
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
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
  Returns all projects that have a local_path set, ordered by name.
  Does not require a scope — intended for the local web project index.

  When `client_user_id` is given, scopes to projects linked by that
  client_user. Projects linked under a previous OAuth session
  (different client_user_id, or unstamped from before the field
  existed) intentionally do not appear — they belong to someone
  else on this machine.
  """
  def list_local_projects(client_user_id \\ nil)

  def list_local_projects(nil) do
    from(p in Project, where: not is_nil(p.local_path), order_by: [asc: p.name])
    |> Repo.all()
  end

  def list_local_projects(client_user_id) do
    from(p in Project,
      where: not is_nil(p.local_path) and p.client_user_id == ^client_user_id,
      order_by: [asc: p.name]
    )
    |> Repo.all()
  end

  @doc """
  Returns true iff some project has a local_path set AND was linked by
  this client_user. Used by the local-install ladder to decide whether
  to surface the linked-project rung as "done."
  """
  def any_linked_project_for_client_user?(nil), do: false

  def any_linked_project_for_client_user?(client_user_id) do
    query =
      from p in Project,
        where: not is_nil(p.local_path) and p.client_user_id == ^client_user_id,
        limit: 1

    Repo.exists?(query)
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
    query =
      from p in Project,
        where: p.local_path == ^path,
        order_by: [desc: p.updated_at],
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  def get_project!(%Scope{} = scope, id) do
    Repo.get_by!(Project, id: id, account_id: scope.active_account_id)
  end

  @doc """
  Gets a project by id without an auth-bound scope.

  For use by web-side plugs / supervisors that load a project before
  the scope has been fully constructed (e.g. building scope from an
  `X-Project-ID` header). Auth-checked callers should use
  `get_project!/2` with a scope.
  """
  @spec get_project_by_id(String.t()) :: Project.t() | nil
  def get_project_by_id(id) when is_binary(id) do
    Repo.get(Project, id)
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc """
  Looks up a project by its deploy key via the deterministic hash blind index.
  Lets the chat widget authenticate with only the deploy key — no project id.
  """
  @spec get_project_by_deploy_key(String.t()) :: Project.t() | nil
  def get_project_by_deploy_key(deploy_key) when is_binary(deploy_key) do
    case Project.hash_deploy_key(deploy_key) do
      nil -> nil
      hash -> Repo.get_by(Project, deploy_key_hash: hash)
    end
  end

  @doc """
  Returns the distinct `account_id` for every project that has a
  `local_path` set. Used by `CodeMySpecLocalWeb.SocketSupervisor` at
  boot to start one socket per local-tracked account.
  """
  @spec list_local_account_ids() :: [Ecto.UUID.t()]
  def list_local_account_ids do
    from(p in Project,
      where: not is_nil(p.local_path) and not is_nil(p.account_id),
      select: p.account_id,
      distinct: true
    )
    |> Repo.all()
  end

  @doc """
  Returns any one project in the given account that has a
  `local_path` set, or `nil`. Used by the local socket supervisor
  to bootstrap a scope per local account.
  """
  @spec first_local_project_for_account(Ecto.UUID.t() | nil) :: Project.t() | nil
  def first_local_project_for_account(nil), do: nil

  def first_local_project_for_account(account_id) do
    from(p in Project,
      where: p.account_id == ^account_id and not is_nil(p.local_path),
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Preloads the project's OAuth application association.

  Provides a stable hook for the project show LiveView to refresh
  the association after a `:updated` broadcast without reaching
  past the context into Repo.preload directly.
  """
  @spec preload_oauth_application(Project.t()) :: Project.t()
  def preload_oauth_application(%Project{} = project) do
    Repo.preload(project, :oauth_application)
  end

  @doc """
  Same as `preload_oauth_application/1` but reloads the association
  even if it was already loaded. Used after broadcast updates.
  """
  @spec reload_oauth_application(Project.t()) :: Project.t()
  def reload_oauth_application(%Project{} = project) do
    Repo.preload(project, :oauth_application, force: true)
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
  Returns the OAuth application for a project, creating one if it doesn't exist.
  Returns `{:ok, project, plaintext_secret}` on creation or `{:error, reason}`.
  """
  def get_or_create_oauth_app(%Scope{} = scope, %Project{} = project) do
    true = project.account_id == scope.active_account_id

    project = Repo.preload(project, :oauth_application)

    case project.oauth_application do
      nil -> create_oauth_app(scope, project)
      _app -> {:ok, project, nil}
    end
  end

  defp create_oauth_app(%Scope{} = scope, %Project{} = project) do
    plaintext_secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    attrs = %{
      name: "#{project.name} MCP Client",
      redirect_uri: "http://localhost:0/callback",
      scopes: "read write",
      uid: "mcp_" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)),
      secret: plaintext_secret
    }

    case Repo.transaction(fn -> insert_and_link_oauth_app(scope, project, attrs) end) do
      {:ok, project} -> {:ok, project, plaintext_secret}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_and_link_oauth_app(scope, project, attrs) do
    with {:ok, oauth_app} <- %Application{} |> Application.changeset(attrs) |> Repo.insert(),
         {:ok, updated_project} <-
           update_project(scope, project, %{oauth_application_id: oauth_app.id}) do
      Repo.preload(updated_project, :oauth_application, force: true)
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  @doc """
  Regenerates the client secret for a project's OAuth application.
  Returns `{:ok, project, plaintext_secret}` or `{:error, reason}`.
  """
  def regenerate_oauth_secret(%Scope{} = scope, %Project{} = project) do
    true = project.account_id == scope.active_account_id

    project = Repo.preload(project, :oauth_application, force: true)

    case project.oauth_application do
      nil ->
        {:error, :no_oauth_app}

      oauth_app ->
        plaintext_secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

        case oauth_app |> Application.changeset(%{secret: plaintext_secret}) |> Repo.update() do
          {:ok, _updated_app} ->
            {:ok, Repo.preload(project, :oauth_application, force: true), plaintext_secret}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  Removes the OAuth application from a project and deletes the application record.
  """
  def delete_oauth_app(%Scope{} = scope, %Project{} = project) do
    true = project.account_id == scope.active_account_id

    project = Repo.preload(project, :oauth_application, force: true)

    case project.oauth_application do
      nil ->
        {:ok, project}

      oauth_app ->
        Repo.transaction(fn -> unlink_and_delete_oauth_app(scope, project, oauth_app) end)
    end
  end

  defp unlink_and_delete_oauth_app(scope, project, oauth_app) do
    case update_project(scope, project, %{oauth_application_id: nil}) do
      {:ok, updated_project} ->
        Repo.delete!(oauth_app)
        %{updated_project | oauth_application: nil}

      {:error, changeset} ->
        Repo.rollback(changeset)
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
      {:ok, %{"html_url" => url}} ->
        {:ok, url}

      {:error, :github_not_connected} ->
        {:error, :github_not_connected}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
