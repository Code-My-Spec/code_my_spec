defmodule CodeMySpec.Requirements.RequirementsRepositoryTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.RequirementsFixtures

  alias CodeMySpec.Requirements.RequirementsRepository

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope)
    scope = user_scope_fixture(user, account, project)
    component = component_fixture(scope)

    %{scope: scope, project: project, component: component, user: user, account: account}
  end

  describe "create_requirement/3" do
    test "creates a requirement with valid data", %{scope: scope, component: component} do
      attrs = requirement_attrs()

      assert {:ok, requirement} =
               RequirementsRepository.create_requirement(scope, component, attrs)

      assert requirement.name == "design_file"
      assert requirement.satisfied == false
      assert requirement.component_id == component.id
    end

    test "returns error with invalid data", %{scope: scope, component: component} do
      attrs = requirement_attrs(%{satisfied: nil})

      assert {:error, changeset} =
               RequirementsRepository.create_requirement(scope, component, attrs)

      assert changeset.errors[:satisfied]
    end
  end

  describe "update_requirement/3" do
    test "updates requirement with valid data", %{scope: scope, component: component} do
      {:ok, requirement} =
        RequirementsRepository.create_requirement(scope, component, requirement_attrs())

      update_attrs = %{satisfied: true, details: %{reason: "File found"}}

      assert {:ok, updated} =
               RequirementsRepository.update_requirement(scope, requirement, update_attrs)

      assert updated.satisfied == true
      assert updated.details == %{reason: "File found"}
    end

    test "returns error with invalid data", %{scope: scope, component: component} do
      {:ok, requirement} =
        RequirementsRepository.create_requirement(scope, component, requirement_attrs())

      invalid_attrs = %{satisfied: nil}

      assert {:error, changeset} =
               RequirementsRepository.update_requirement(scope, requirement, invalid_attrs)

      assert changeset.errors[:satisfied]
    end
  end
end
