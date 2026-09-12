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
  alias CodeMySpec.UserPreferences
  alias CodeMySpec.Users.User

  defstruct user: nil,
            user_id: nil,
            active_account: nil,
            active_account_id: nil,
            active_project: nil,
            active_project_id: nil,
            active_working_copy_id: nil,
            cwd: nil,
            environment: nil

  @type t :: %__MODULE__{
          user: User.t() | ClientUser.t() | nil,
          user_id: Ecto.UUID.t() | integer() | nil,
          active_account: Account.t() | nil,
          active_account_id: Ecto.UUID.t() | nil,
          # A project struct, whatever shape `CodeMySpec.Projects.Project`
          # currently has — Scope carries it without depending on that
          # module's compiled type. Users → Projects would be the wrong
          # direction (a project belongs to an account, which is many-to-many
          # on users, not the other way round).
          active_project: struct() | nil,
          active_project_id: Ecto.UUID.t() | nil,
          # Which working copy of the project this scope speaks for. Files and
          # problems are projections of one checkout, so a read or write of them
          # without this is a statement about the project that no checkout made.
          # `nil` outside a harness's channel — the web UI, mix tasks, anything
          # asking about the project rather than a copy of it.
          active_working_copy_id: Ecto.UUID.t() | nil,
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
        # The active project is a *fallback*, not the answer. Every LiveView
        # under /app/projects/:project_id gets its project from the URL, put on
        # the scope per-request by the PortableHosts, which overwrite whatever
        # is here — so the bug this used to cause (a link landing on a page
        # showing a different project than the one it named) stays fixed.
        #
        # It is still read because the REST API has no project in its URL:
        # /api/issues is what `Issues.RemoteClient` calls from the shipped CLI,
        # and IssuesRepository.resolve_project_id/1 has no other way to know
        # which project a request means. Removing it 500s that endpoint.
        # Deleting this for real means project-scoping the API routes, which
        # is a breaking change for CLIs already in the field.
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

  @doc """
  Builds a complete local scope from a project record, preferring a live
  checkout over `local_path`.

  No config.yml needed. `resolve_environment/2` checks a live-registered
  harness first — a currently-connected checkout wins over a stale or absent
  column — and falls back to `root || project.local_path` only when nothing
  is registered.

  A `root` may be supplied to override the persisted `local_path`. A sprite
  clones to a path it chooses at runtime and is not the only checkout of that
  project, so the column is neither authoritative nor necessarily set for it —
  the caller that did the cloning is.

  Errors only when neither source resolves anything — a project with no
  `local_path`, no `root`, and no live registration is genuinely reachable
  nowhere, not merely missing a column. Failing that case here, once, means
  every caller of this function gets the live-registry check for free instead
  of each having to know to ask for it — a project onboarded outside the
  usual `local_path`-setting flow (an adopted, pre-existing checkout with a
  live harness but no persisted column) used to read as unreachable even
  while a harness was actively connected to it.
  """
  @spec for_local_project(struct(), String.t() | nil) :: {:ok, t()} | {:error, atom()}
  def for_local_project(project, root \\ nil)

  def for_local_project(nil, _root), do: {:error, :no_local_path}

  # `%_{}` — any struct, not specifically `CodeMySpec.Projects.Project` — is
  # the point: every caller already holds a real project, and matching on the
  # module by name would make Scope depend on Projects' compiled type for no
  # reason a project belongs to an account, not to Users.
  def for_local_project(%_{} = project, root) do
    case resolve_environment(project, root) do
      %Environment{cwd: nil} ->
        {:error, :no_local_path}

      env ->
        user = default_local_user()

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
  # in-memory env so the LiveView (which rebuilds scope from the project
  # record) gets the same env the test set up. Production projects have no
  # registration and get a default :local env.
  #
  # A root-specific registration wins over the project's, because an
  # environment describes a *working copy* and a project can have several. With
  # only the project key, every harness on a project resolved to one env, so a
  # second agent scanned the first one's files — and story 892's scenarios,
  # which turn on one agent holding a component no other checkout has, could
  # not be written at all. The reclaim deleted the component and the live
  # agent's own sync re-projected it from what it believed was its working
  # copy, which is correct behaviour on a false premise.
  defp resolve_environment(%_{} = project, root) do
    case registered_for(root) || CodeMySpec.Environments.lookup_registered(project.id) do
      nil -> Environment.new(:local, root || project.local_path)
      %Environment{} = env -> env
    end
  end

  defp registered_for(nil), do: nil
  defp registered_for(root), do: CodeMySpec.Environments.lookup_registered({:root, root})

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

end
