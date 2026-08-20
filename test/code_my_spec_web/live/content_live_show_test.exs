defmodule CodeMySpecWeb.ContentLive.ShowTest do
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

  describe "with a synced snapshot row" do
    setup [:create_snapshot]

    test "renders the row's processed content for the scoped project", %{
      project: project,
      conn: conn,
      snapshot: snapshot
    } do
      {:ok, _live, html} = live(conn, ~p"/app/projects/#{project.id}/content/#{snapshot.id}")

      refute html =~ "content-not-found"
      assert html =~ "Hello World"
      assert html =~ "<h1>Hello</h1>"
    end
  end

  test "renders a not-found state for an id with no matching row", %{
    project: project,
    conn: conn
  } do
    {:ok, _live, html} = live(conn, ~p"/app/projects/#{project.id}/content/999")

    assert html =~ "content-not-found"
    assert html =~ "Content not found."
  end
end
