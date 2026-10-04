defmodule CodeMySpec.UserPreferencesTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.UserPreferences

  describe "user_preferences" do
    alias CodeMySpec.UserPreferences.UserPreference

    import CodeMySpec.UsersFixtures, only: [user_scope_fixture: 0, user_scope_fixture: 2]
    import CodeMySpec.UserPreferencesFixtures
    import CodeMySpec.AccountsFixtures, only: [account_with_owner_fixture: 1]
    import CodeMySpec.ProjectsFixtures, only: [project_fixture: 1]

    @invalid_attrs %{token: nil, active_account_id: nil, active_project_id: nil}

    test "get_user_preference/1 returns user preferences for scoped user" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      user_preference = user_preference_fixture(scope)
      user_preference_fixture(other_scope)

      assert {:ok, ^user_preference} = UserPreferences.get_user_preference(scope)
      assert {:ok, _} = UserPreferences.get_user_preference(other_scope)
    end

    test "get_user_preference/1 returns error when no preferences exist" do
      scope = user_scope_fixture()
      assert {:error, :not_found} = UserPreferences.get_user_preference(scope)
    end

    test "get_user_preference!/1 returns the user_preference for scoped user" do
      scope = user_scope_fixture()
      user_preference = user_preference_fixture(scope)
      assert UserPreferences.get_user_preference!(scope) == user_preference
    end

    test "get_user_preference!/1 raises when no preferences exist" do
      scope = user_scope_fixture()
      assert_raise Ecto.NoResultsError, fn -> UserPreferences.get_user_preference!(scope) end
    end

    test "create_user_preferences/2 with valid data creates a user_preference" do
      project_id = Ecto.UUID.generate()
      account_id = Ecto.UUID.generate()

      valid_attrs = %{
        token: "some token",
        active_account_id: account_id,
        active_project_id: project_id
      }

      scope = user_scope_fixture()

      assert {:ok, %UserPreference{} = user_preference} =
               UserPreferences.create_user_preferences(scope, valid_attrs)

      assert user_preference.token == "some token"
      assert user_preference.active_account_id == account_id
      assert user_preference.active_project_id == project_id
      assert user_preference.user_id == scope.user.id
    end

    # Two first requests at once each found no row; the second insert raised
    # on user_preferences_user_id_index and served a 500.
    test "a second row for the same user is a changeset error, not a crash" do
      scope = user_scope_fixture()
      {:ok, _} = UserPreferences.create_user_preferences(scope, @invalid_attrs)

      assert {:error, %Ecto.Changeset{errors: [user_id: _]}} =
               UserPreferences.create_user_preferences(scope, @invalid_attrs)
    end

    test "create_user_preferences/2 with invalid data succeeds with nil values" do
      scope = user_scope_fixture()

      assert {:ok, %UserPreference{} = user_preference} =
               UserPreferences.create_user_preferences(scope, @invalid_attrs)

      assert user_preference.active_account_id == nil
      assert user_preference.active_project_id == nil
      assert user_preference.token == nil
      assert user_preference.user_id == scope.user.id
    end

    test "update_user_preferences/2 with valid data updates the user_preference" do
      scope = user_scope_fixture()
      user_preference_fixture(scope)
      project_id = Ecto.UUID.generate()
      account_id = Ecto.UUID.generate()

      update_attrs = %{
        token: "some updated token",
        active_account_id: account_id,
        active_project_id: project_id
      }

      assert {:ok, %UserPreference{} = user_preference} =
               UserPreferences.update_user_preferences(scope, update_attrs)

      assert user_preference.token == "some updated token"
      assert user_preference.active_account_id == account_id
      assert user_preference.active_project_id == project_id
    end

    test "update_user_preferences/2 with invalid data succeeds with nil values" do
      scope = user_scope_fixture()
      user_preference_fixture(scope)

      assert {:ok, %UserPreference{} = user_preference} =
               UserPreferences.update_user_preferences(scope, @invalid_attrs)

      assert user_preference.active_account_id == nil
      assert user_preference.active_project_id == nil
      assert user_preference.token == nil
      assert user_preference.user_id == scope.user.id
    end

    test "delete_user_preferences/1 deletes the user_preference" do
      scope = user_scope_fixture()
      user_preference_fixture(scope)
      assert {:ok, %UserPreference{}} = UserPreferences.delete_user_preferences(scope)
      assert {:error, :not_found} = UserPreferences.get_user_preference(scope)
    end

    test "change_user_preferences/2 returns a user_preference changeset" do
      scope = user_scope_fixture()
      user_preference_fixture(scope)
      assert %Ecto.Changeset{} = UserPreferences.change_user_preferences(scope)
    end

    test "change_user_preferences/2 returns changeset for new preference when none exists" do
      scope = user_scope_fixture()
      assert %Ecto.Changeset{} = UserPreferences.change_user_preferences(scope)
    end

    test "select_active_account/2 creates preference with account when none exists" do
      scope = user_scope_fixture()
      account = account_with_owner_fixture(scope.user)

      assert {:ok, %UserPreference{} = user_preference} =
               UserPreferences.select_active_account(scope, account.id)

      assert user_preference.active_account_id == account.id
      assert user_preference.user_id == scope.user.id
    end

    test "select_active_account/2 updates existing preference" do
      scope = user_scope_fixture()
      user_preference_fixture(scope)
      account = account_with_owner_fixture(scope.user)

      assert {:ok, %UserPreference{} = user_preference} =
               UserPreferences.select_active_account(scope, account.id)

      assert user_preference.active_account_id == account.id
      assert user_preference.user_id == scope.user.id
    end

    test "select_active_account/2 refuses an account the user is not a member of" do
      scope = user_scope_fixture()
      other_account = account_with_owner_fixture(user_scope_fixture().user)

      assert {:error, :not_a_member} =
               UserPreferences.select_active_account(scope, other_account.id)
    end

    test "select_active_project/2 creates preference with project when none exists" do
      scope = user_scope_fixture()
      account = account_with_owner_fixture(scope.user)
      project = project_fixture(user_scope_fixture(scope.user, account))

      assert {:ok, %UserPreference{} = user_preference} =
               UserPreferences.select_active_project(scope, project.id)

      assert user_preference.active_project_id == project.id
      assert user_preference.user_id == scope.user.id
    end

    test "select_active_project/2 updates existing preference" do
      scope = user_scope_fixture()
      user_preference_fixture(scope)
      account = account_with_owner_fixture(scope.user)
      project = project_fixture(user_scope_fixture(scope.user, account))

      assert {:ok, %UserPreference{} = user_preference} =
               UserPreferences.select_active_project(scope, project.id)

      assert user_preference.active_project_id == project.id
      assert user_preference.user_id == scope.user.id
    end

    test "select_active_project/2 refuses a project on an account the user is not a member of" do
      scope = user_scope_fixture()
      other_user_scope = user_scope_fixture()
      other_account = account_with_owner_fixture(other_user_scope.user)
      project = project_fixture(user_scope_fixture(other_user_scope.user, other_account))

      assert {:error, :not_a_member} =
               UserPreferences.select_active_project(scope, project.id)
    end

    test "generate_token/1 creates preference with token when none exists" do
      scope = user_scope_fixture()
      assert {:ok, %UserPreference{} = user_preference} = UserPreferences.generate_token(scope)
      assert is_binary(user_preference.token)
      assert user_preference.user_id == scope.user.id
    end

    test "generate_token/1 updates existing preference with new token" do
      scope = user_scope_fixture()
      user_preference_fixture(scope)
      assert {:ok, %UserPreference{} = user_preference} = UserPreferences.generate_token(scope)
      assert is_binary(user_preference.token)
      assert user_preference.user_id == scope.user.id
    end
  end
end
