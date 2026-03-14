defmodule CodeMySpecWeb.StoryLiveTest do
  use CodeMySpecTest.ConnCase

  import Phoenix.LiveViewTest
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.AcceptanceCriteriaFixtures
  import CodeMySpec.TagsFixtures

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.Tags

  defp create_attrs do
    %{
      status: :in_progress,
      description: "some description",
      title: Faker.Lorem.word()
    }
  end

  @update_attrs %{
    status: :completed,
    description: "some updated description",
    title: "some updated title"
  }
  @invalid_attrs %{
    status: nil,
    description: nil,
    title: nil
  }

  setup [:register_log_in_setup_account, :setup_active_account, :setup_active_project]

  defp create_story(%{scope: scope}) do
    story = story_fixture(scope)

    %{story: story}
  end

  defp create_story_with_criteria(%{scope: scope}) do
    story = story_fixture(scope, %{criteria: []})
    criterion = criterion_fixture(scope, story)

    %{story: CodeMySpec.Stories.get_story!(scope, story.id), criterion: criterion}
  end

  describe "Index" do
    setup [:create_story]

    test "lists all stories", %{conn: conn, story: story} do
      {:ok, _index_live, html} = live(conn, ~p"/app/stories")

      assert html =~ "Listing Stories"
      assert html =~ story.title
    end

    test "toggle criteria checkbox changes visibility", %{conn: conn, story: story} do
      {:ok, index_live, _html} = live(conn, ~p"/app/stories")

      # First verify the story appears
      html = render(index_live)
      assert html =~ story.title
      assert html =~ "Acceptance Criteria:"

      # Click toggle to hide criteria - criteria text should disappear
      html =
        index_live
        |> element("input[phx-click='toggle_criteria']")
        |> render_click()

      assert html =~ story.title
      refute html =~ "Acceptance Criteria:"

      # Click toggle again - criteria text should reappear
      html =
        index_live
        |> element("input[phx-click='toggle_criteria']")
        |> render_click()

      assert html =~ story.title
      assert html =~ "Acceptance Criteria:"
    end

    test "saves new story", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/app/stories")

      assert {:ok, form_live, _} =
               index_live
               |> element("a", "New Story")
               |> render_click()
               |> follow_redirect(conn, ~p"/app/stories/new")

      assert render(form_live) =~ "New Story"

      assert form_live
             |> form("#story-form", story: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      attrs = %{title: title} = create_attrs()

      assert {:ok, index_live, _html} =
               form_live
               |> form("#story-form", story: attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/app/stories")

      html = render(index_live)
      assert html =~ "Story created successfully"
      assert html =~ title
    end

    test "updates story in listing", %{conn: conn, story: story} do
      {:ok, index_live, _html} = live(conn, ~p"/app/stories")

      assert {:ok, form_live, _html} =
               index_live
               |> element("#stories-#{story.id} a", "Edit")
               |> render_click()
               |> follow_redirect(conn, ~p"/app/stories/#{story}/edit")

      assert render(form_live) =~ "Edit Story"

      assert form_live
             |> form("#story-form", story: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, index_live, _html} =
               form_live
               |> form("#story-form", story: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/app/stories")

      html = render(index_live)
      assert html =~ "Story updated successfully"
      assert html =~ "some updated title"
    end

    test "deletes story in listing", %{conn: conn, story: story} do
      {:ok, index_live, _html} = live(conn, ~p"/app/stories")

      assert index_live |> element("#stories-#{story.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#stories-#{story.id}")
    end
  end

  describe "Show" do
    setup [:create_story]

    test "displays story", %{conn: conn, story: story} do
      {:ok, _show_live, html} = live(conn, ~p"/app/stories/#{story}")

      assert html =~ "Show Story"
      assert html =~ story.title
    end

    test "updates story and returns to show", %{conn: conn, story: story} do
      {:ok, show_live, _html} = live(conn, ~p"/app/stories/#{story}")

      assert {:ok, form_live, _} =
               show_live
               |> element("a", "Edit")
               |> render_click()
               |> follow_redirect(conn, ~p"/app/stories/#{story}/edit?return_to=show")

      assert render(form_live) =~ "Edit Story"

      assert form_live
             |> form("#story-form", story: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, show_live, _html} =
               form_live
               |> form("#story-form", story: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/app/stories/#{story}")

      html = render(show_live)
      assert html =~ "Story updated successfully"
      assert html =~ "some updated title"
    end
  end

  describe "Criteria" do
    setup [:create_story_with_criteria]

    test "displays criteria on show page", %{conn: conn, story: story, criterion: criterion} do
      {:ok, _show_live, html} = live(conn, ~p"/app/stories/#{story}")

      assert html =~ criterion.description
    end

    test "displays criteria on index page", %{conn: conn, story: story, criterion: criterion} do
      {:ok, _index_live, html} = live(conn, ~p"/app/stories")

      assert html =~ story.title
      assert html =~ criterion.description
    end

    test "toggles criterion verified status", %{
      conn: conn,
      scope: scope,
      story: story,
      criterion: criterion
    } do
      {:ok, show_live, html} = live(conn, ~p"/app/stories/#{story}")

      # Initially not verified
      refute criterion.verified
      assert html =~ "hero-lock-open"

      # Click to verify
      show_live
      |> element("button[phx-click='toggle_verified'][phx-value-id='#{criterion.id}']")
      |> render_click()

      # Check it's now verified
      updated_criterion = AcceptanceCriteria.get_criterion!(scope, criterion.id)
      assert updated_criterion.verified
      assert updated_criterion.verified_at

      # Click again to unverify
      show_live
      |> element("button[phx-click='toggle_verified'][phx-value-id='#{criterion.id}']")
      |> render_click()

      # Check it's now unverified
      updated_criterion = AcceptanceCriteria.get_criterion!(scope, criterion.id)
      refute updated_criterion.verified
      refute updated_criterion.verified_at
    end

    test "updates criterion description via form", %{conn: conn, scope: scope, story: story} do
      {:ok, form_live, _html} = live(conn, ~p"/app/stories/#{story}/edit")

      original_criterion = List.first(story.criteria)

      # Update the criterion description
      html =
        form_live
        |> form("#story-form", %{
          "story" => %{
            "title" => story.title,
            "description" => story.description,
            "criteria" => %{
              "0" => %{
                "id" => to_string(original_criterion.id),
                "description" => "Updated criterion description"
              }
            },
            "criteria_sort" => ["0"]
          }
        })
        |> render_submit()

      assert {:ok, _index_live, _html} = follow_redirect(html, conn, ~p"/app/stories")

      # Verify the criterion was updated
      updated_story = CodeMySpec.Stories.get_story!(scope, story.id)
      assert length(updated_story.criteria) == 1
      assert List.first(updated_story.criteria).description == "Updated criterion description"
    end

    test "updates criterion verified status via form checkbox", %{
      conn: conn,
      scope: scope,
      story: story
    } do
      {:ok, form_live, _html} = live(conn, ~p"/app/stories/#{story}/edit")

      original_criterion = List.first(story.criteria)
      refute original_criterion.verified

      # Check the verified checkbox
      html =
        form_live
        |> form("#story-form", %{
          "story" => %{
            "title" => story.title,
            "description" => story.description,
            "criteria" => %{
              "0" => %{
                "id" => to_string(original_criterion.id),
                "description" => original_criterion.description,
                "verified" => "true"
              }
            },
            "criteria_sort" => ["0"]
          }
        })
        |> render_submit()

      assert {:ok, _index_live, _html} = follow_redirect(html, conn, ~p"/app/stories")

      # Verify the criterion is now verified
      updated_story = CodeMySpec.Stories.get_story!(scope, story.id)
      assert length(updated_story.criteria) == 1
      assert List.first(updated_story.criteria).verified == true
    end
  end

  describe "Tags" do
    setup [:create_story]

    test "displays tags on show page", %{conn: conn, scope: scope, story: story} do
      story_tagging_fixture(scope, story, "my-test-tag")

      {:ok, _show_live, html} = live(conn, ~p"/app/stories/#{story}")

      assert html =~ "my-test-tag"
    end

    test "displays tags on index page", %{conn: conn, scope: scope, story: story} do
      story_tagging_fixture(scope, story, "index-tag")

      {:ok, _index_live, html} = live(conn, ~p"/app/stories")

      assert html =~ "index-tag"
    end

    test "adds tag to story", %{conn: conn, scope: scope, story: story} do
      {:ok, show_live, _html} = live(conn, ~p"/app/stories/#{story}")

      # Add a tag via the form
      show_live
      |> form("form[phx-submit='add_tag']", %{tag: "new-tag"})
      |> render_submit()

      # Verify the tag appears in the UI
      html = render(show_live)
      assert html =~ "new-tag"

      # Verify it was persisted
      tags = Tags.list_story_tags(scope, story)
      assert Enum.any?(tags, &(&1.name == "new-tag"))
    end

    test "removes tag from story", %{conn: conn, scope: scope, story: story} do
      story_tagging_fixture(scope, story, "remove-me")

      {:ok, show_live, html} = live(conn, ~p"/app/stories/#{story}")

      # Verify tag is initially present
      assert html =~ "remove-me"

      # Click remove button
      show_live
      |> element("button[phx-click='remove_tag'][phx-value-tag='remove-me']")
      |> render_click()

      # Verify the tag is removed from UI
      html = render(show_live)
      refute html =~ "remove-me"

      # Verify it was removed from database
      tags = Tags.list_story_tags(scope, story)
      refute Enum.any?(tags, &(&1.name == "remove-me"))
    end

    test "adding duplicate tag is idempotent", %{conn: conn, scope: scope, story: story} do
      story_tagging_fixture(scope, story, "existing-tag")

      {:ok, show_live, _html} = live(conn, ~p"/app/stories/#{story}")

      # Try to add the same tag again
      show_live
      |> form("form[phx-submit='add_tag']", %{tag: "existing-tag"})
      |> render_submit()

      # Should still only have one tag
      tags = Tags.list_story_tags(scope, story)
      assert length(Enum.filter(tags, &(&1.name == "existing-tag"))) == 1
    end

    test "ignores empty tag input", %{conn: conn, scope: scope, story: story} do
      {:ok, show_live, _html} = live(conn, ~p"/app/stories/#{story}")

      # Submit empty tag
      show_live
      |> form("form[phx-submit='add_tag']", %{tag: "   "})
      |> render_submit()

      # Should have no tags
      tags = Tags.list_story_tags(scope, story)
      assert Enum.empty?(tags)
    end
  end
end
