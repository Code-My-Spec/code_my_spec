defmodule CodeMySpecWeb.ComponentLive.FormTest do
  use CodeMySpecWeb.ConnCase

  import Phoenix.LiveViewTest
  import CodeMySpec.ComponentsFixtures

  @create_attrs %{
    name: "UserService",
    type: "genserver",
    module_name: "CodeMySpec.Services.UserService",
    description: "Handles user operations"
  }
  @update_attrs %{
    name: "UpdatedUserService",
    type: "context",
    module_name: "CodeMySpec.Contexts.UpdatedUserService",
    description: "Updated user operations"
  }
  @invalid_attrs %{
    name: nil,
    type: nil,
    module_name: nil,
    description: nil
  }

  setup [:register_log_in_setup_account, :setup_active_account, :setup_active_project]

  defp create_component(%{scope: scope}) do
    component = component_fixture(scope)
    %{component: component}
  end

  describe "New" do
    test "saves new component", %{conn: conn} do
      {:ok, form_live, _html} = live(conn, ~p"/app/components/new")

      assert render(form_live) =~ "New Component"

      assert form_live
             |> form("#component-form", component: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, _, html} =
               form_live
               |> form("#component-form", component: @create_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/app/components")

      assert html =~ "Component created successfully"
      assert html =~ "UserService"
    end
  end

  describe "Edit" do
    setup [:create_component]

    test "displays edit form", %{conn: conn, component: component} do
      {:ok, _form_live, html} = live(conn, ~p"/app/components/#{component}/edit")

      assert html =~ "Edit Component"
      assert html =~ component.name
    end

    test "updates component", %{conn: conn, component: component} do
      {:ok, form_live, _html} = live(conn, ~p"/app/components/#{component}/edit")

      assert form_live
             |> form("#component-form", component: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, _, html} =
               form_live
               |> form("#component-form", component: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/app/components")

      assert html =~ "Component updated successfully"
      assert html =~ "UpdatedUserService"
    end

    test "validates module name format", %{conn: conn, component: component} do
      {:ok, form_live, _html} = live(conn, ~p"/app/components/#{component}/edit")

      assert form_live
             |> form("#component-form", component: %{module_name: "invalid_module_name"})
             |> render_change() =~ "must be a valid Elixir module name"
    end

    test "validates unique module name", %{conn: conn, component: component, scope: scope} do
      existing_component = component_fixture(scope, %{module_name: "MyApp.ExistingModule"})

      {:ok, form_live, _html} = live(conn, ~p"/app/components/#{component}/edit")

      assert form_live
             |> form("#component-form", component: %{module_name: existing_component.module_name})
             |> render_submit() =~ "has already been taken"
    end
  end
end
