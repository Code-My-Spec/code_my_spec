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

  describe "resolving scope.environment (issue 780ca909)" do
    # `scope` here comes from a signed-in HTTP session (`Scope.for_user/1`),
    # which never sets `environment` — the same scope PortableHost's on_mount
    # amends with the routed project. Without that amendment,
    # `ContentPublishing.sync/1` calls `Environments.glob(nil, _)`, which
    # returns `[]` unconditionally: Re-sync would always find nothing, no
    # matter what is really on disk.
    setup %{scope: scope, project: project} do
      {:ok, tmp_dir} = Briefly.create(directory: true)

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
