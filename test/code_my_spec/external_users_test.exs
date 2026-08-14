defmodule CodeMySpec.ExternalUsersTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.{UsersFixtures, ProjectsFixtures}

  alias CodeMySpec.ExternalUsers

  setup do
    scope = full_scope_fixture()
    project = project_fixture(scope)

    {:ok, scope: scope, project: project}
  end

  describe "upsert_external_user/3" do
    test "creates a user keyed by project and email", %{project: project} do
      assert {:ok, user} =
               ExternalUsers.upsert_external_user(project.account_id, project.id, %{
                 email: "jane@example.com",
                 external_id: "usr_42",
                 name: "Jane",
                 metadata: %{"platform" => "macos"}
               })

      assert user.project_id == project.id
      assert user.account_id == project.account_id
      assert user.email == "jane@example.com"
      assert user.metadata == %{"platform" => "macos"}
    end

    test "repeat upsert on the same email refreshes instead of duplicating", %{project: project} do
      {:ok, first} =
        ExternalUsers.upsert_external_user(project.account_id, project.id, %{
          email: "jane@example.com",
          name: "Jane"
        })

      {:ok, second} =
        ExternalUsers.upsert_external_user(project.account_id, project.id, %{
          email: "jane@example.com",
          name: "Jane D.",
          external_id: "usr_42"
        })

      assert second.id == first.id
      assert second.name == "Jane D."
      assert second.external_id == "usr_42"
      assert [_only_one] = ExternalUsers.list_external_users(project.id)
    end

    test "same email on different projects stays separate", %{scope: scope, project: project} do
      other_project = project_fixture(scope)

      {:ok, a} =
        ExternalUsers.upsert_external_user(project.account_id, project.id, %{
          email: "jane@example.com"
        })

      {:ok, b} =
        ExternalUsers.upsert_external_user(other_project.account_id, other_project.id, %{
          email: "jane@example.com"
        })

      assert a.id != b.id
    end

    test "missing email is a validation error", %{project: project} do
      assert {:error, changeset} =
               ExternalUsers.upsert_external_user(project.account_id, project.id, %{name: "Jane"})

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end
  end
end
