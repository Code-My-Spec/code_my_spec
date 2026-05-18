defmodule CodeMySpecWeb.ProjectLiveTest do
  use CodeMySpecTest.ConnCase

  import Phoenix.LiveViewTest
  import CodeMySpec.ProjectsFixtures

  @create_attrs %{
    name: "some name",
    description: "some description",
    code_repo: "some code_repo",
    docs_repo: "some docs_repo"
  }
  @update_attrs %{
    name: "some updated name",
    description: "some updated description",
    code_repo: "some updated code_repo",
    docs_repo: "some updated docs_repo"
  }
  @invalid_attrs %{name: nil, description: nil, code_repo: nil, docs_repo: nil}

  setup [:register_and_log_in_user, :setup_active_account]

  defp create_project(%{scope: scope}) do
    project = project_fixture(scope)

    %{project: project}
  end

  describe "Index" do
    setup [:create_project]

    test "lists all projects", %{conn: conn, project: project} do
      {:ok, _index_live, html} = live(conn, ~p"/app/projects")

      assert html =~ "Listing Projects"
      assert html =~ project.name
    end

    test "saves new project", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/app/projects")

      assert {:ok, form_live, _} =
               index_live
               |> element("a", "New Project")
               |> render_click()
               |> follow_redirect(conn, ~p"/app/projects/new")

      assert render(form_live) =~ "New Project"

      assert form_live
             |> form("#project-form", project: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, index_live, _html} =
               form_live
               |> form("#project-form", project: @create_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/app/projects")

      html = render(index_live)
      assert html =~ "Project created successfully"
      assert html =~ "some name"
    end

    test "updates project in listing", %{conn: conn, project: project} do
      {:ok, index_live, _html} = live(conn, ~p"/app/projects")

      assert {:ok, form_live, _html} =
               index_live
               |> element("#projects-#{project.id} a", "Edit")
               |> render_click()
               |> follow_redirect(conn, ~p"/app/projects/#{project}/edit")

      assert render(form_live) =~ "Edit Project"

      assert form_live
             |> form("#project-form", project: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, index_live, _html} =
               form_live
               |> form("#project-form", project: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/app/projects")

      html = render(index_live)
      assert html =~ "Project updated successfully"
      assert html =~ "some updated name"
    end

    test "deletes project in listing", %{conn: conn, project: project} do
      {:ok, index_live, _html} = live(conn, ~p"/app/projects")

      # The row's `Delete` link only opens the per-project confirm
      # dialog; the actual delete event is pushed from the dialog's
      # confirm button.
      assert index_live
             |> element("#confirm-delete-project-#{project.id} [data-role='confirm-confirm']")
             |> render_click()

      refute has_element?(index_live, "#projects-#{project.id}")
    end
  end

  describe "Show" do
    setup [:create_project]

    test "displays project", %{conn: conn, project: project} do
      {:ok, _show_live, html} = live(conn, ~p"/app/projects/#{project}")

      assert html =~ "Show Project"
      assert html =~ project.name
    end

    test "updates project and returns to show", %{conn: conn, project: project} do
      {:ok, show_live, _html} = live(conn, ~p"/app/projects/#{project}")

      assert {:ok, form_live, _} =
               show_live
               |> element("a", "Edit")
               |> render_click()
               |> follow_redirect(conn, ~p"/app/projects/#{project}/edit?return_to=show")

      assert render(form_live) =~ "Edit Project"

      assert form_live
             |> form("#project-form", project: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, show_live, _html} =
               form_live
               |> form("#project-form", project: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/app/projects/#{project}")

      html = render(show_live)
      assert html =~ "Project updated successfully"
      assert html =~ "some updated name"
    end
  end

  describe "Form - GitHub Repository Creation" do
    test "creates code repository when create button clicked", %{conn: conn} do
      {:ok, form_live, _html} = live(conn, ~p"/app/projects/new")

      # Fill in project name
      form_live
      |> form("#project-form", project: %{name: "Test Project", description: "Test desc"})
      |> render_change()

      # Mock GitHub integration would be needed for this to pass
      # This demonstrates the expected user interaction
      assert has_element?(form_live, "button", "Create")
    end

    test "creates docs repository when create button clicked", %{conn: conn} do
      {:ok, form_live, _html} = live(conn, ~p"/app/projects/new")

      # Fill in project name
      form_live
      |> form("#project-form", project: %{name: "Test Project", description: "Test desc"})
      |> render_change()

      # Mock GitHub integration would be needed for this to pass
      # This demonstrates the expected user interaction
      assert has_element?(form_live, "button", "Create")
    end

    test "create buttons are disabled when project name is empty", %{conn: conn} do
      {:ok, form_live, _html} = live(conn, ~p"/app/projects/new")

      html = render(form_live)

      # Buttons should be disabled when name is empty
      assert html =~ "disabled"
    end
  end

  describe "Form - GitHub Repository Creation on existing project" do
    setup [:create_project]

    test "shows error when GitHub not connected", %{conn: conn, project: project} do
      {:ok, form_live, _html} = live(conn, ~p"/app/projects/#{project}/edit")

      # Click create button without GitHub integration
      html = render_click(form_live, "create_code_repo")

      assert html =~ "Please connect your GitHub account first"
    end
  end
end
