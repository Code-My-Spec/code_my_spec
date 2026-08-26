defmodule CodeMySpec.Utils.DataTest do
  @moduledoc """
  Moves one project's data between environments — never the account it lives
  under, its members, its users, or any other project the account owns.

  Account-level sync used to be the tool for this: export/import a whole
  account, wiping and reinserting every project it owned. That meant a real
  account holding several real projects (a personal account with a dozen
  side projects on it, say) lost every one of them but the one being synced,
  and the wipe itself resolved "which accounts does this touch" by walking
  from the target account to its members' user ids and back out to every
  account those users belong to — deleting all of them whenever a user held
  membership in more than one. Scoping to a project id instead removes both
  failure modes: nothing here ever looks past the one project's own rows.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.IssuesFixtures

  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.User
  alias CodeMySpec.Utils.Data

  defp export_path do
    Path.join(System.tmp_dir!(), "data_test_export_#{System.unique_integer([:positive])}.json")
  end

  describe "import_project/2" do
    test "does not touch a sibling project under the same account" do
      user = user_fixture()

      account =
        account_with_owner_fixture(user, %{name: "Shared account #{System.unique_integer()}"})

      scope_a = user_scope_fixture(user, account)
      project_a = project_fixture(scope_a, %{name: "MarketMySpec"})

      story_a =
        story_fixture(%{scope_a | active_project_id: project_a.id, active_project: project_a})

      scope_b = user_scope_fixture(user, account)
      project_b = project_fixture(scope_b, %{name: "CodeMySpec"})

      story_b =
        story_fixture(%{scope_b | active_project_id: project_b.id, active_project: project_b})

      path = export_path()
      on_exit(fn -> File.rm(path) end)

      Data.export_project(project_a.id, path)
      Data.import_project(path)

      assert Repo.get(Account, account.id), "the shared account was deleted"
      assert Repo.get(User, user.id), "the shared user was deleted"

      assert Repo.get(Project, project_b.id), "the sibling project was deleted"
      assert Repo.get(Story, story_b.id), "the sibling project's story was deleted"

      assert Repo.get(Project, project_a.id)
      assert Repo.get(Story, story_a.id)
    end

    test "does not touch an unrelated account" do
      user_a = user_fixture()

      account_a =
        account_with_owner_fixture(user_a, %{name: "Account A #{System.unique_integer()}"})

      scope_a = user_scope_fixture(user_a, account_a)
      project_a = project_fixture(scope_a, %{name: "MarketMySpec"})

      _story_a =
        story_fixture(%{scope_a | active_project_id: project_a.id, active_project: project_a})

      user_b = user_fixture()

      account_b =
        account_with_owner_fixture(user_b, %{name: "Account B #{System.unique_integer()}"})

      scope_b = user_scope_fixture(user_b, account_b)
      project_b = project_fixture(scope_b, %{name: "Unrelated"})

      story_b =
        story_fixture(%{scope_b | active_project_id: project_b.id, active_project: project_b})

      path = export_path()
      on_exit(fn -> File.rm(path) end)

      Data.export_project(project_a.id, path)
      Data.import_project(path)

      assert Repo.get(Account, account_b.id)
      assert Repo.get(User, user_b.id)
      assert Repo.get(Project, project_b.id)
      assert Repo.get(Story, story_b.id)
    end

    test "re-importing the same export is idempotent" do
      user = user_fixture()

      account =
        account_with_owner_fixture(user, %{name: "Re-imported #{System.unique_integer()}"})

      scope = user_scope_fixture(user, account)
      project = project_fixture(scope, %{name: "Original project"})
      story = story_fixture(%{scope | active_project_id: project.id, active_project: project})

      path = export_path()
      on_exit(fn -> File.rm(path) end)

      Data.export_project(project.id, path)

      # A later sync re-exports and re-imports the project's full current
      # state — the second run must not collide with rows the first run
      # already inserted (versions in particular: PaperTrail writes one per
      # insert, so the export itself grows a version row every time it runs).
      Data.import_project(path)
      Data.import_project(path)

      assert Repo.get(Project, project.id)
      assert Repo.get(Story, story.id)
    end

    test "refuses to destroy children the export cannot put back" do
      user = user_fixture()
      account = account_with_owner_fixture(user, %{name: "Has issues #{System.unique_integer()}"})
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope, %{name: "Market My Spec"})
      project_scope = %{scope | active_project_id: project.id, active_project: project}

      path = export_path()
      on_exit(fn -> File.rm(path) end)
      Data.export_project(project.id, path)

      # After the export, so the file cannot contain it. This is the shape of
      # the near-miss: an export taken from an empty environment, imported over
      # the environment that holds the real work.
      issue = issue_fixture(project_scope)

      assert {:error, {:would_destroy, project_id, losses}} = Data.import_project(path)
      assert project_id == project.id
      assert {"issues", 1} in losses

      # The refusal is the point: the row is still there.
      assert Repo.get(Issue, issue.id)

      # And it names what would go, rather than a constraint.
      message = Data.explain({:would_destroy, project_id, losses})
      assert message =~ "1 issues"
      assert message =~ "force: true"
    end

    test "force proceeds for a caller that has read the refusal" do
      user = user_fixture()
      account = account_with_owner_fixture(user, %{name: "Forced #{System.unique_integer()}"})
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope, %{name: "Forced project"})
      project_scope = %{scope | active_project_id: project.id, active_project: project}

      path = export_path()
      on_exit(fn -> File.rm(path) end)
      Data.export_project(project.id, path)

      issue = issue_fixture(project_scope)

      assert {:ok, _} = Data.import_project(path, force: true)

      # Gone, as the refusal said it would be — nothing in the file restores it.
      refute Repo.get(Issue, issue.id)
      assert Repo.get(Project, project.id)
    end

    test "refuses when the destination account does not exist" do
      user = user_fixture()
      account = account_with_owner_fixture(user, %{name: "Vanishing #{System.unique_integer()}"})
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope, %{name: "Orphaned project"})

      path = export_path()
      on_exit(fn -> File.rm(path) end)
      Data.export_project(project.id, path)

      # Stands in for an export carried to an environment that has never heard
      # of the account. Deleting the project first keeps the account delete from
      # cascading into rows the assertion is about.
      Repo.delete_all(from p in Project, where: p.id == ^project.id)
      Repo.delete_all(from a in Account, where: a.id == ^account.id)

      assert {:error, {:missing_account, account_id, "Orphaned project"}} =
               Data.import_project(path)

      assert account_id == account.id

      # No project was created under an account that is not there.
      refute Repo.get(Project, project.id)
    end
  end
end
