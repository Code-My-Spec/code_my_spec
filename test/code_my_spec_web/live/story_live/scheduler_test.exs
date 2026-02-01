defmodule CodeMySpecWeb.StoryLive.SchedulerTest do
  use CodeMySpecWeb.ConnCase

  import Phoenix.LiveViewTest
  import CodeMySpec.StoriesFixtures

  setup [:register_log_in_setup_account, :setup_active_account, :setup_active_project]

  defp create_stories(%{scope: scope}) do
    # Create stories with different priorities
    high_priority =
      story_fixture(scope, %{
        title: "High Priority Story",
        priority: 1
      })

    medium_priority =
      story_fixture(scope, %{
        title: "Medium Priority Story",
        priority: 5
      })

    no_priority =
      story_fixture(scope, %{
        title: "No Priority Story",
        priority: nil
      })

    %{
      high_priority: high_priority,
      medium_priority: medium_priority,
      no_priority: no_priority
    }
  end

  describe "Scheduler Index" do
    setup [:create_stories]

    test "displays scheduler page with stories", %{
      conn: conn,
      high_priority: high_priority,
      medium_priority: medium_priority,
      no_priority: no_priority
    } do
      {:ok, _scheduler_live, html} = live(conn, ~p"/app/stories/scheduler")

      assert html =~ "Story Scheduler"
      assert html =~ "Drag and drop to prioritize stories"
      assert html =~ high_priority.title
      assert html =~ medium_priority.title
      assert html =~ no_priority.title
    end

    test "shows stories in priority order", %{
      conn: conn,
      high_priority: high_priority,
      medium_priority: medium_priority,
      no_priority: no_priority
    } do
      {:ok, _scheduler_live, html} = live(conn, ~p"/app/stories/scheduler")

      # Check that priorities are displayed correctly
      assert html =~ "1"
      assert html =~ "5"
      # No priority (dash)
      assert html =~ "—"

      # Stories should be in priority order (lower number = higher priority)
      high_pos = :binary.match(html, high_priority.title) |> elem(0)
      medium_pos = :binary.match(html, medium_priority.title) |> elem(0)
      no_priority_pos = :binary.match(html, no_priority.title) |> elem(0)

      assert high_pos < medium_pos
      assert medium_pos < no_priority_pos
    end

    test "displays story information correctly", %{
      conn: conn,
      high_priority: high_priority
    } do
      {:ok, _scheduler_live, html} = live(conn, ~p"/app/stories/scheduler")

      assert html =~ high_priority.title
      assert html =~ high_priority.description
    end

    test "shows drag handle and priority for each story", %{conn: conn} do
      {:ok, _scheduler_live, html} = live(conn, ~p"/app/stories/scheduler")

      # Drag cursor class
      assert html =~ "cursor-move"
      # Drag handle icon
      assert html =~ "hero-bars-3"
      # Sortable container ID
      assert html =~ "scheduler-list"
      # LiveView hook
      assert html =~ "StoryScheduler"
    end

    test "includes SortableJS hook configuration", %{conn: conn} do
      {:ok, _scheduler_live, html} = live(conn, ~p"/app/stories/scheduler")

      # The hook name appears in the phx-hook attribute
      assert html =~ "StoryScheduler"
      # The container has the necessary data attributes for sorting
      assert html =~ "data-story-id"
    end

    test "handles reorder_priorities event", %{
      conn: conn,
      high_priority: high_priority,
      medium_priority: medium_priority,
      no_priority: no_priority
    } do
      {:ok, scheduler_live, _html} = live(conn, ~p"/app/stories/scheduler")

      # Simulate reordering stories
      new_order = [
        to_string(medium_priority.id),
        to_string(high_priority.id),
        to_string(no_priority.id)
      ]

      scheduler_live
      |> element("#scheduler-list")
      |> render_hook("reorder_priorities", %{"story_ids" => new_order})

      # Verify the stories are displayed in new priority order
      html = render(scheduler_live)

      # Check that stories now appear in the new order in the HTML
      medium_pos = :binary.match(html, medium_priority.title) |> elem(0)
      high_pos = :binary.match(html, high_priority.title) |> elem(0)
      no_priority_pos = :binary.match(html, no_priority.title) |> elem(0)

      # Medium should appear first, then high, then no priority
      assert medium_pos < high_pos
      assert high_pos < no_priority_pos
    end

    test "ignores invalid story IDs in reorder", %{
      conn: conn,
      scope: scope,
      high_priority: high_priority
    } do
      {:ok, scheduler_live, _html} = live(conn, ~p"/app/stories/scheduler")

      # Include a non-existent story ID
      new_order = [
        to_string(high_priority.id),
        # Non-existent ID
        "999999999"
      ]

      # Should not crash
      scheduler_live
      |> element("#scheduler-list")
      |> render_hook("reorder_priorities", %{"story_ids" => new_order})

      # High priority story should still be updated
      updated_high = CodeMySpec.Stories.get_story!(scope, high_priority.id)
      assert updated_high.priority == 1
    end

    test "displays criteria count", %{conn: conn} do
      {:ok, _scheduler_live, html} = live(conn, ~p"/app/stories/scheduler")

      assert html =~ "Criteria:"
    end

    test "updates when stories are created, updated, or deleted", %{
      conn: conn,
      scope: scope
    } do
      {:ok, scheduler_live, _html} = live(conn, ~p"/app/stories/scheduler")

      # Create a new story
      new_story =
        story_fixture(scope, %{
          title: "New Test Story",
          priority: 10
        })

      # The LiveView should automatically update via PubSub
      html = render(scheduler_live)
      assert html =~ new_story.title
    end

    test "maintains proper stream attributes", %{conn: conn} do
      {:ok, _scheduler_live, html} = live(conn, ~p"/app/stories/scheduler")

      assert html =~ "phx-update=\"stream\""
      assert html =~ "id=\"scheduler-list\""
    end

    test "includes proper CSS classes for drag and drop", %{conn: conn} do
      {:ok, _scheduler_live, html} = live(conn, ~p"/app/stories/scheduler")

      # Prevents text selection
      assert html =~ "select-none"
      # Shows drag cursor
      assert html =~ "cursor-move"
      # Hover effects
      assert html =~ "hover:shadow-lg"
      # Smooth transitions
      assert html =~ "transition-all"
    end
  end
end
