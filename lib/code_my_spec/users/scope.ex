defmodule CodeMySpec.Users.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `CodeMySpec.Users.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use as authorization, or to
  ensure specific code paths can only be access for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.
  """

  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.ClientUsers.ClientUser
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.UserPreferences
  alias CodeMySpec.Users.User

  defstruct user: nil,
            user_id: nil,
            active_account: nil,
            active_account_id: nil,
            active_project: nil,
            active_project_id: nil,
            cwd: nil,
            environment: nil

  @type t :: %__MODULE__{
          user: User.t() | ClientUser.t() | nil,
          user_id: Ecto.UUID.t() | integer() | nil,
          active_account: Account.t() | nil,
          active_account_id: Ecto.UUID.t() | nil,
          active_project: Project.t() | nil,
          active_project_id: Ecto.UUID.t() | nil,
          cwd: String.t() | nil,
          environment: Environment.t() | nil
        }

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    scope = %__MODULE__{user: user, user_id: user.id}

    case UserPreferences.get_user_preference(scope) do
      {:ok, preferences} ->
        %__MODULE__{
          user: user,
          user_id: user.id,
          active_account: preferences.active_account,
          active_account_id: preferences.active_account_id,
          active_project: preferences.active_project,
          active_project_id: preferences.active_project_id
        }

      {:error, :not_found} ->
        scope
    end
  end

  def for_user(nil), do: nil

  @config_dir ".code_my_spec"
  @config_file "config.yml"

  @doc """
  Creates a scope from a local project config file.

  Reads `.code_my_spec/config.yml` from the given project root directory,
  loads or creates the project, and returns a scope.

  Used by CLI and local MCP server for non-OAuth authenticated access.
  Expects the project root (containing `.code_my_spec/config.yml`) - callers
  should resolve subdirectories to the project root before calling this.

  Returns `{:ok, scope}` or `{:error, reason}`.
  """
  @spec from_local_config(String.t()) :: {:ok, t()} | {:error, atom() | String.t()}
  def from_local_config(project_root) when is_binary(project_root) do
    with {:ok, config} <- read_local_config(project_root),
         {:ok, project} <- get_or_create_project(config, project_root) do
      user = default_local_user()

      {:ok,
       %__MODULE__{
         user: user,
         user_id: user.id,
         active_account: nil,
         active_account_id: config["account_id"],
         active_project: project,
         active_project_id: project.id,
         cwd: project_root,
         environment: Environment.new(:local, project_root)
       }}
    end
  end

  def from_local_config(nil), do: {:error, :no_working_dir}

  @doc """
  Builds a complete local scope from a project record that has `local_path` set.

  No config.yml needed — uses the project's persisted `local_path` for the environment.
  """
  @spec for_local_project(Project.t()) :: {:ok, t()} | {:error, atom()}
  @spec for_local_project(Project.t()) :: {:ok, t()} | {:error, atom()}
  def for_local_project(%Project{local_path: nil}), do: {:error, :no_local_path}

  def for_local_project(%Project{} = project) do
    user = default_local_user()
    env = resolve_environment(project)

    {:ok,
     %__MODULE__{
       user: user,
       user_id: user.id,
       active_account: nil,
       active_account_id: project.account_id,
       active_project: project,
       active_project_id: project.id,
       cwd: env.cwd,
       environment: env
     }}
  end

  @doc """
  Builds a minimal local scope carrying only the working directory — no
  linked project.

  Used by bootstrap flows like `/codemyspec:init` that need a cwd and
  environment but must run *before* any project is linked. Project-scoped
  code paths see `active_project: nil` and fail with a clean "no project"
  error instead of being blocked at the router.
  """
  @spec for_local_cwd(String.t() | nil) :: {:ok, t()} | {:error, :no_working_dir}
  def for_local_cwd(nil), do: {:error, :no_working_dir}

  def for_local_cwd(working_dir) when is_binary(working_dir) do
    user = default_local_user()

    {:ok,
     %__MODULE__{
       user: user,
       user_id: user.id,
       active_account: nil,
       active_account_id: nil,
       active_project: nil,
       active_project_id: nil,
       cwd: working_dir,
       environment: Environment.new(:local, working_dir)
     }}
  end

  # Consult the environment registry first — spex tests register an
  # in-memory env per project so the LiveView (which rebuilds scope from
  # the project record) gets the same env the test set up. Production
  # projects have no registration and get a default :local env.
  defp resolve_environment(%Project{} = project) do
    case CodeMySpec.Environments.lookup_registered(project.id) do
      nil -> Environment.new(:local, project.local_path)
      %Environment{} = env -> env
    end
  end

  # Default user for local/CLI contexts where no OAuth user is available
  defp default_local_user do
    %ClientUser{
      id: 0,
      email: "cli@localhost",
      oauth_token: nil,
      oauth_refresh_token: nil,
      oauth_expires_at: nil
    }
  end

  @doc """
  Reads the local config file from the project root directory.

  Expects a directory containing `.code_my_spec/config.yml`.

  Returns `{:ok, config_map}` or `{:error, reason}`.
  """
  @spec read_local_config(String.t()) :: {:ok, map()} | {:error, atom()}
  def read_local_config(project_root) do
    config_path = Path.join([project_root, @config_dir, @config_file])

    case YamlElixir.read_from_file(config_path) do
      {:ok, config} when is_map(config) -> {:ok, config}
      {:ok, nil} -> {:ok, %{}}
      {:error, _reason} -> {:error, :config_parse_error}
    end
  end

  defp get_or_create_project(config, working_dir) do
    case config["project_id"] do
      nil ->
        {:error, :no_project_id}

      project_id ->
        case CodeMySpec.Repo.get(Project, project_id) do
          %Project{} = project ->
            sync_project_from_config(project, config, working_dir)

          nil ->
            create_project_from_config(config, working_dir)
        end
    end
  end

  defp sync_project_from_config(project, config, working_dir) do
    attrs =
      %{}
      |> maybe_put(:name, config["name"])
      |> maybe_put(:module_name, config["module_name"])
      |> maybe_put(:description, config["description"])
      |> maybe_put(:account_id, config["account_id"])
      |> maybe_put(:local_path, working_dir)

    if attrs == %{} do
      {:ok, project}
    else
      project
      |> Ecto.Changeset.cast(attrs, Map.keys(attrs))
      |> CodeMySpec.Repo.update()
    end
  end

  defp create_project_from_config(config, working_dir) do
    attrs = %{
      id: config["project_id"],
      name: config["name"] || "Unnamed Project",
      module_name: config["module_name"] || "App",
      description: config["description"],
      account_id: config["account_id"],
      local_path: working_dir
    }

    CodeMySpec.Repo.insert(struct(Project, attrs))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
