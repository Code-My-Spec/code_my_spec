defmodule CodeMySpecWeb.ContentLiveTest do
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CodeMySpec.ContentPublishing.Snapshot
  alias CodeMySpec.Repo

  setup [:register_log_in_setup_account, :setup_active_project]

  defp create_snapshot(%{project: project}) do
    {:ok, snapshot} =
      %Snapshot{}
      |> Snapshot.changeset(%{
        raw_content: "# Hello",
        processed_content: "<h1>Hello</h1>",
        parse_status: :success,
        metadata: %{"slug" => "hello-world", "content_type" => "post", "title" => "Hello World"},
        project_id: project.id
      })
      |> Repo.insert()

    %{snapshot: snapshot}
  end

  test "renders the content page for the scoped project", %{project: project, conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/app/projects/#{project.id}/content")

    assert html =~ "Content"
    assert html =~ "content-summary"
    assert html =~ "publish-button"
  end

  describe "with a synced snapshot row" do
    setup [:create_snapshot]

    test "lists the row's content instead of rendering an empty page", %{
      project: project,
      conn: conn
    } do
      {:ok, _live, html} = live(conn, ~p"/app/projects/#{project.id}/content")

      assert html =~ "hello-world"
      assert html =~ "1 success, 0 error"
      assert html =~ "content-row-link-hello-world"
    end
  end

  describe "resolving the content environment" do
    # The HTTP session scope can lack an environment. Content sync resolves the
    # routed project's local environment explicitly before reading the source.
    setup %{scope: scope, project: project} do
      tmp_dir = CodeMySpec.TempFile.owned_dir("test")

      File.write!(Path.join(tmp_dir, "hello.md"), """
      ---
      title: Hello
      slug: hello
      content_type: page
      ---
      Body.
      """)

      {:ok, project} =
        CodeMySpec.Projects.update_project(scope, project, %{
          local_path: tmp_dir,
          content_source_path: tmp_dir
        })

      %{project: project}
    end

    test "Re-sync finds the real file on disk instead of silently reporting zero", %{
      project: project,
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/app/projects/#{project.id}/content")

      html = view |> element("[data-test='sync-button']") |> render_click()

      assert html =~ "1 success, 0 error"
      assert html =~ "content-row-link-hello"
    end
  end
end
