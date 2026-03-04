defmodule CodeMySpec.ComponentsTest do
  use CodeMySpecTest.DataCase

  alias CodeMySpec.Components

  describe "components" do
    import CodeMySpec.UsersFixtures
    import CodeMySpec.ComponentsFixtures

    test "update_component/3 with invalid scope raises" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      component = component_fixture(scope)

      assert_raise MatchError, fn ->
        Components.update_component(other_scope, component, %{})
      end
    end

    test "delete_component/2 with invalid scope raises" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      component = component_fixture(scope)

      assert_raise MatchError, fn ->
        Components.delete_component(other_scope, component)
      end
    end

    test "change_component/2 returns a component changeset" do
      scope = full_scope_fixture()
      component = component_fixture(scope)
      assert %Ecto.Changeset{} = Components.change_component(scope, component)
    end

    test "change_component/2 with invalid scope raises" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      component = component_fixture(scope)

      assert_raise MatchError, fn ->
        Components.change_component(other_scope, component)
      end
    end
  end
end
