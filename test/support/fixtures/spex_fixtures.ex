defmodule CodeMySpecSpex.Fixtures do
  @moduledoc """
  Approved bridge from spex tests into app-level DB setup.

  Specs can only reach into the app through this module. The boundary
  enforces it: `CodeMySpecSpex` depends on `CodeMySpecSpex.Fixtures`,
  not on `CodeMySpec` or `CodeMySpecTest` directly.

  Only surfaces fixtures for state that **originates server-side and
  syncs into the local app** — users, accounts, projects, stories.
  Local-only state (ProjectConfiguration, etc.) must be set up through
  the UI like any other user action.
  """
  use Boundary, deps: [CodeMySpec, CodeMySpecTest]

  alias CodeMySpec.{
    AccountsFixtures,
    Components,
    ComponentsFixtures,
    EnvironmentFixtures,
    Environments,
    ProblemsFixtures,
    ProjectsFixtures,
    SessionsFixtures,
    Stories,
    StoriesFixtures,
    UserPreferences,
    Users,
    UsersFixtures
  }

  alias CodeMySpecTest.DataCase

  # -- Sandbox / session setup --
  defdelegate setup_sandbox(tags), to: DataCase

  def generate_user_session_token(user), do: Users.generate_user_session_token(user)
  def select_active_account(scope, account_id), do: UserPreferences.select_active_account(scope, account_id)
  def select_active_project(scope, project_id), do: UserPreferences.select_active_project(scope, project_id)

  # -- Environments --
  defdelegate memory_environment_fixture(opts \\ []), to: EnvironmentFixtures
  defdelegate register_environment(project_id, env), to: Environments, as: :register
  defdelegate unregister_environment(project_id), to: Environments, as: :unregister

  # -- Users --
  defdelegate user_fixture(attrs \\ %{}), to: UsersFixtures
  defdelegate user_scope_fixture(), to: UsersFixtures
  defdelegate user_scope_fixture(user), to: UsersFixtures
  defdelegate user_scope_fixture(user, account), to: UsersFixtures
  defdelegate user_scope_fixture(user, account, project), to: UsersFixtures
  defdelegate full_scope_fixture(), to: UsersFixtures
  defdelegate full_scope_fixture(project_attrs), to: UsersFixtures

  # -- Accounts --
  defdelegate account_fixture(attrs \\ %{}), to: AccountsFixtures
  defdelegate account_with_owner_fixture(user, attrs \\ %{}), to: AccountsFixtures
  defdelegate member_fixture(user, account, role \\ :member), to: AccountsFixtures

  # -- Projects --
  defdelegate project_fixture(scope, attrs \\ %{}), to: ProjectsFixtures

  # -- Components --
  defdelegate component_fixture(scope, attrs \\ %{}), to: ComponentsFixtures
  defdelegate get_component_by_module_name(scope, module_name), to: Components

  # -- Stories --
  defdelegate story_fixture(scope, attrs \\ %{}), to: StoriesFixtures
  defdelegate set_story_component(scope, story, component_id), to: Stories

  # -- Sessions --
  defdelegate session_fixture(scope, attrs \\ %{}), to: SessionsFixtures

  # -- Problems --
  defdelegate problem_fixture(scope, attrs \\ %{}), to: ProblemsFixtures
end
