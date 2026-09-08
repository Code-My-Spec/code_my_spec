defmodule CodeMySpec.UserPreferencesFixtures do
  @moduledoc """
  Test data for `CodeMySpec.UserPreferences`.
  """

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures

  @doc """
  Generate a user_preference.
  """
  def user_preference_fixture(scope, attrs \\ %{}) do
    # Create actual account and project if not provided
    account = account_fixture()
    project = project_fixture(scope)

    attrs =
      Enum.into(attrs, %{
        active_account_id: account.id,
        active_project_id: project.id,
        token: "some token"
      })

    {:ok, user_preference} = CodeMySpec.UserPreferences.create_user_preferences(scope, attrs)
    user_preference
  end
end
