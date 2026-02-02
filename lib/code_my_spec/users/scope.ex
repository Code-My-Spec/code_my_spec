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

  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Users.User
  alias CodeMySpec.ClientUsers.ClientUser
  alias CodeMySpec.UserPreferences

  defstruct user: nil,
            user_id: nil,
            active_account: nil,
            active_account_id: nil,
            active_project: nil,
            active_project_id: nil

  @type t :: %__MODULE__{
          user: User.t() | ClientUser.t() | nil,
          user_id: Ecto.UUID.t() | integer() | nil,
          active_account: Account.t() | nil,
          active_account_id: Ecto.UUID.t() | nil,
          active_project: Project.t() | nil,
          active_project_id: Ecto.UUID.t() | nil
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

  Reads `.code_my_spec/config.yml` from the given working directory,
  loads or creates the project, and returns a scope.

  Used by CLI and local MCP server for non-OAuth authenticated access.

  Returns `{:ok, scope}` or `{:error, reason}`.
  """
  @spec from_local_config(String.t()) :: {:ok, t()} | {:error, atom() | String.t()}
  def from_local_config(working_dir) when is_binary(working_dir) do
    with {:ok, config} <- read_local_config(working_dir),
         {:ok, project} <- get_or_create_project(config, working_dir) do
      user = default_local_user()

      {:ok,
       %__MODULE__{
         user: user,
         user_id: user.id,
         active_account: nil,
         active_account_id: config["account_id"],
         active_project: project,
         active_project_id: project.id
       }}
    end
  end

  def from_local_config(nil), do: {:error, :no_working_dir}

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
  Reads the local config file from the working directory.

  Returns `{:ok, config_map}` or `{:error, reason}`.
  """
  @spec read_local_config(String.t()) :: {:ok, map()} | {:error, atom()}
  def read_local_config(working_dir) do
    config_path = Path.join([working_dir, @config_dir, @config_file])

    if File.exists?(config_path) do
      case YamlElixir.read_from_file(config_path) do
        {:ok, config} when is_map(config) -> {:ok, config}
        {:ok, nil} -> {:ok, %{}}
        {:error, _reason} -> {:error, :config_parse_error}
      end
    else
      {:error, :config_not_found}
    end
  end

  defp get_or_create_project(config, working_dir) do
    case config["project_id"] do
      nil ->
        {:error, :no_project_id}

      project_id ->
        case CodeMySpec.Repo.get(Project, project_id) do
          %Project{} = project ->
            {:ok, project}

          nil ->
            create_project_from_config(config, working_dir)
        end
    end
  end

  defp create_project_from_config(config, _working_dir) do
    attrs = %{
      id: config["project_id"],
      name: config["name"] || "Unnamed Project",
      module_name: config["module_name"] || "App",
      description: config["description"],
      account_id: config["account_id"]
    }

    CodeMySpec.Repo.insert(struct(Project, attrs))
  end
end
