defmodule CodeMySpecWeb.StoryLive.ImportTest do
  use CodeMySpecTest.ConnCase

  import Phoenix.LiveViewTest

  setup [:register_log_in_setup_account, :setup_active_account, :setup_active_project]

  describe "mount/3" do
    test "initializes import page with correct content", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/app/stories/import")

      assert html =~ "Import Stories from Markdown"
      assert html =~ "Upload a markdown file or paste content"
    end
  end

  describe "validate event" do
    test "updates markdown content on change", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/app/stories/import")

      content = "## Test Story\nTest description"

      result = live |> element("form") |> render_change(%{"markdown_content" => content})

      assert result =~ content
    end
  end

  describe "import event" do
    test "imports stories from markdown content successfully", %{conn: conn, scope: scope} do
      {:ok, live, _html} = live(conn, ~p"/app/stories/import")

      markdown_content = """
      ## First Story

      Description of first story.

      **Acceptance Criteria**
      - First criterion
      - Second criterion

      ## Second Story

      Description of second story.

      **Acceptance Criteria**
      - Another criterion
      """

      assert {:error, {:live_redirect, %{to: "/app/stories"}}} =
               live
               |> form("form", %{"markdown_content" => markdown_content})
               |> render_submit()

      stories = CodeMySpec.Stories.list_stories(scope)
      assert length(stories) == 2

      first_story = Enum.find(stories, &(&1.title == "First Story"))
      second_story = Enum.find(stories, &(&1.title == "Second Story"))

      assert first_story.description == "Description of first story."
      assert second_story.description == "Description of second story."
    end

    test "shows error for invalid markdown", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/app/stories/import")

      invalid_content = "This is not valid markdown format"

      live
      |> form("form", %{"markdown_content" => invalid_content})
      |> render_submit()

      assert render(live) =~ "Import failed:"
    end

    test "shows error for empty content", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/app/stories/import")

      live
      |> form("form", %{"markdown_content" => ""})
      |> render_submit()

      assert render(live) =~ "Import failed: Document is empty"
    end

    test "handles story creation failures gracefully", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/app/stories/import")

      markdown_content = """
      ##

      Empty title story.
      """

      live
      |> form("form", %{"markdown_content" => markdown_content})
      |> render_submit()

      assert render(live) =~ "Import failed: Markdown is missing required sections"
    end

    test "shows success message on successful import", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/app/stories/import")

      markdown_content = """
      ## Test Story

      Test description.

      **Acceptance Criteria**
      - Test criterion
      """

      assert {:error, {:live_redirect, %{to: "/app/stories"}}} =
               live
               |> form("form", %{"markdown_content" => markdown_content})
               |> render_submit()
    end
  end

  describe "UI elements" do
    test "displays upload area and form elements", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/app/stories/import")

      assert html =~ "Upload Markdown File"
      assert html =~ "Drop your .md file here"
      assert html =~ "Paste Markdown Content"
      assert html =~ "Import Stories"
      assert html =~ "Cancel"
    end

    test "shows placeholder content in textarea", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/app/stories/import")

      assert html =~ "## Story Title"
      assert html =~ "**Acceptance Criteria**"
    end
  end

  describe "file upload configuration" do
    test "displays file upload input with correct accept types", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/app/stories/import")

      assert html =~ "accept=\".md,.markdown,.txt\""
      assert html =~ "type=\"file\""
    end
  end

  describe "navigation" do
    test "cancel button links to stories index", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/app/stories/import")

      assert html =~ "href=\"/app/stories\""
      assert html =~ "Cancel"
    end
  end
end
