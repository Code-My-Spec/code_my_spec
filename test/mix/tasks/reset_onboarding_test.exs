defmodule Mix.Tasks.ResetOnboardingTest do
  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpec.{Agents, UserPreferences}
  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Projects.Project
  alias Mix.Tasks.ResetOnboarding

  defp owner_scope do
    scope = CodeMySpec.UsersFixtures.full_scope_fixture()

    Repo.update_all(from(m in CodeMySpec.Accounts.Member, where: m.user_id == ^scope.user.id),
      set: [role: :owner]
    )

    scope
  end

  test "no argument resets to models and invalid steps are rejected" do
    assert ResetOnboarding.parse_step!([]) == 1
    assert ResetOnboarding.parse_step!(["1"]) == 1
    assert_raise Mix.Error, fn -> ResetOnboarding.parse_step!(["4"]) end
  end

  for step <- 1..3 do
    test "step #{step} clears that step and later steps, preserving earlier choices" do
      scope = owner_scope()
      other = CodeMySpec.UsersFixtures.full_scope_fixture()
      {:ok, _} = UserPreferences.select_active_account(scope, scope.active_account_id)
      {:ok, _} = UserPreferences.select_active_project(scope, scope.active_project_id)
      {:ok, _} = Agents.put_model_setting(scope, :main, "claude-code", "claude-opus-5-5")
      assert {:ok, :ok} = ResetOnboarding.reset(Repo, scope.user.id, unquote(step))
      refute Repo.get(Project, scope.active_project_id)
      refreshed = UserPreferences.scope_for(scope.user)
      assert refreshed.active_project_id == nil
      assert Agents.models_configured?(refreshed) == unquote(step) > 1
      assert !!Repo.get(Account, scope.active_account_id) == (unquote(step) == 3)
      if unquote(step) <= 2, do: assert(refreshed.active_account_id == nil)
      if unquote(step) == 3, do: assert(refreshed.active_account_id == scope.active_account_id)
      assert Repo.get(Project, other.active_project_id)
      assert Repo.get(Account, other.active_account_id)
      assert Repo.get(CodeMySpec.Users.User, scope.user.id)
    end
  end

  test "shared accounts abort without deleting model settings or projects" do
    scope = owner_scope()
    other = CodeMySpec.UsersFixtures.user_fixture()
    CodeMySpec.AccountsFixtures.member_fixture(other, scope.active_account)
    assert {:error, :shared_accounts} = ResetOnboarding.reset(Repo, scope.user.id, 1)
    assert Repo.get(Project, scope.active_project_id)
  end
end
