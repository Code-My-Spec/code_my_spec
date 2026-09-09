defmodule CodeMySpec.Projects do
  @moduledoc """
  The Projects context.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec, CodeMySpec.Oauth, CodeMySpec.Repo, CodeMySpec.Utils],
    exports: :all

  import Ecto.Query, warn: false
  alias CodeMySpec.Oauth.Application
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils.MapAccess

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
    slug = normalize_project_name(name)

    query =
      from p in Project,
        where: fragment("lower(replace(replace(?, '-', ' '), '_', ' '))", p.name) == ^slug

    case Repo.one(query) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  @doc """
  Gets a project by name (case-insensitive) within the scope's active account.
  For cloud web routes that put the project name, not its id, in the URL.

  A name that doesn't exist and a name that belongs to another account return
  the same `{:error, :not_found}` — confirming a project's existence to
  someone guessing names on another account is its own leak.
  """
  def get_project_by_name(%Scope{} = scope, name) when is_binary(name) do
    slug = normalize_project_name(name)

    query =
      from p in Project,
        where: p.account_id == ^scope.active_account_id,
        where: fragment("lower(replace(replace(?, '-', ' '), '_', ' '))", p.name) == ^slug

    case Repo.one(query) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  defp normalize_project_name(name),
    do: name |> String.replace(~r/[-_]/, " ") |> String.downcase()

  @doc """
  Resolves which project a local request belongs to.

  Two mechanisms, in priority order:

    * `:project_id` in application config — a sprite is provisioned for exactly
      one project and is told which at boot, so it never has to infer identity
      from a directory. `working_dir` is ignored entirely.
    * `working_dir` — the desktop CLI serves many projects from one process, so
      "which project is this directory?" is a real question there.

  The directory lookup is a poor identity key on shared data: two checkouts of
  one project have two paths but one column, and `/workspace/<app>` is a
  plausible collision across sprites. Configuring the id sidesteps both by not
  asking the question.
  """
  def resolve_local_project(working_dir) do
    # Identity in precedence order, most specific first:
    #
    #   1. `:project_id` app env (CMS_PROJECT_ID) — the whole VM serves one
    #      project. This is a sprite.
    #   2. `project_id` in the project's own `.code_my_spec/config.yml` — the
    #      per-project answer, and the one a laptop needs when a single harness
    #      serves several checkouts.
    #   3. `local_path` lookup — the original mechanism, kept so existing
    #      installs keep working. It is the one that cannot survive the split:
    #      it is a database lookup keyed by a filesystem path, and the server
    #      that will own these tools has no filesystem.
    #
    # `Elixir.Application` explicitly: this module aliases
    # `CodeMySpec.Oauth.Application`, which shadows the OTP module.
    case Elixir.Application.get_env(:code_my_spec, :project_id) do
      nil -> resolve_from_config_or_path(working_dir)
      project_id -> fetch_project(project_id)
    end
  end

  defp resolve_from_config_or_path(working_dir) when is_binary(working_dir) do
    case project_id_from_config(working_dir) do
      nil -> get_project_by_local_path(working_dir)
      project_id -> fetch_project(project_id)
    end
  end

  defp resolve_from_config_or_path(_), do: {:error, :no_working_dir}

  # A config file that names a project this database does not have is a
  # mistake worth surfacing rather than falling through to a path lookup that
  # would quietly bind the directory to some *other* project.
  defp project_id_from_config(working_dir) do
    case Scope.read_local_config(working_dir) do
      {:ok, %{"project_id" => id}} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp fetch_project(project_id) do
    case Repo.get(Project, project_id) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  @doc """
  Gets a project by its local filesystem path.

  Not for resolving a request: hooks and MCP name a harness, and its record says
  which project. This answers the reverse question — which project claims a path
  — for startup config and the harness's own identity check.
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
  The project's deploy key, minting one if it has none.

  A machine running this project's application authenticates as the project,
  and a deploy key is the only credential it can hold — a container has no
  browser to complete an OAuth flow in. So anything that starts one has to be
  able to get a key rather than find one already there.

  Nothing mints a key at creation. Provisioning mints its own at the secrets
  step, which is fine for a project that gets deployed and useless for one that
  is merely run: a cloud workspace came up with no `CMS_DEPLOY_KEY`, so its
  onboarding could not authenticate and the copy got no preview. Everything
  reported success — the container ran, the app served — and the only missing
  piece was the one nobody was watching.

  Existing keys are returned untouched. Rotating here would break an already
  deployed application that is authenticating with the old one.
  """
  @spec ensure_deploy_key(Scope.t(), Project.t()) :: {:ok, Project.t()} | {:error, term()}
  def ensure_deploy_key(%Scope{}, %Project{deploy_key: key} = project)
      when is_binary(key) and key != "",
      do: {:ok, project}

  def ensure_deploy_key(%Scope{} = scope, %Project{} = project) do
    update_project(scope, project, %{deploy_key: Project.mint_deploy_key()})
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
           |> Project.changeset(with_deploy_key(attrs), scope)
           |> Repo.insert() do
      broadcast(scope, {:created, project})
      {:ok, project}
    end
  end

  # Every project needs one, so it gets one here rather than the first time
  # something happens to ask.
  #
  # A key is what a harness presents to join a project's channel. Without one a
  # project's first checkout cannot join at all: the daemon falls back to
  # whatever key it was started with, which belongs to a different project, and
  # the join is refused. QA 963 walked into that — a project made through the
  # form, a checkout onboarded onto it, and a first message that could not be
  # delivered — and nothing on the way named a missing key.
  #
  # `ensure_deploy_key/2` existed and had one caller, `Workspaces`, which mints
  # lazily at the moment an instance needs a credential. Lazy is right there and
  # wrong here: joining is not an occasion anybody triggers, it is what a
  # checkout does the moment it exists.
  #
  # Minted into the insert rather than by an update afterwards, so a listener
  # never sees `{:updated, …}` for a project it has not seen created. The
  # Generate control on the form is a rotate now, which is what it always read
  # as.
  defp with_deploy_key(attrs) do
    case deploy_key_in(attrs) do
      key when is_binary(key) and key != "" -> attrs
      _ -> put_attr(attrs, "deploy_key", Project.mint_deploy_key())
    end
  end

  defp deploy_key_in(attrs) when is_map(attrs), do: MapAccess.get(attrs, :deploy_key)

  defp deploy_key_in(_attrs), do: nil

  # Whichever key style the caller used. A form sends strings and a fixture
  # sends atoms, and mixing them in one map means the changeset reads only half.
  defp put_attr(attrs, key, value) when is_map(attrs) do
    if Enum.any?(Map.keys(attrs), &is_atom/1),
      do: Map.put(attrs, String.to_existing_atom(key), value),
      else: Map.put(attrs, key, value)
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
