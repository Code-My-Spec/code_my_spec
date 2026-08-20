defmodule CodeMySpecWeb.ContentLiveTest do
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CodeMySpec.Repo
  alias CodeMySpec.ContentPublishing.Snapshot

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
end
