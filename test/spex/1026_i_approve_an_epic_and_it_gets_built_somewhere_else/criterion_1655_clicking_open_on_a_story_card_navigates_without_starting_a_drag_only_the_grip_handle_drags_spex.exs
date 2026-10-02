defmodule CodeMySpecSpex.Story1026.Criterion1655Spex do
  @moduledoc """
  Story 1026 — I approve an epic and it gets built somewhere else.
  Criterion 1655 — Clicking Open on a story card navigates without starting a
  drag; only the grip handle drags.

  The whole card used to be the drag surface, so a link on it would have its
  click swallowed. The drag now starts only from a grip, and Open sits outside
  it.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures

  cloud_endpoint()

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Open navigates; the grip drags", criterion: 1655 do
    scenario "clicking Open on an unfiled story" do
      given_ "an unfiled story on the dashboard", context do
        story = Fixtures.authored_story(context.scope, "Export orders to CSV")
        {:ok, Map.put(context, :story, story)}
      end

      when_ "I click Open on its card", context do
        {:ok, live, _html} = live(context.conn, ~p"/app/projects/#{context.project.id}/epics")
        card = "#unassigned-story-#{context.story.id}"

        result = live |> element("#{card} a[data-test='open-story']") |> render_click()

        {:ok, Map.merge(context, %{live: live, card: card, result: result})}
      end

      then_ "I am taken to the story's page", context do
        href = ~p"/app/projects/#{context.project.id}/stories/#{context.story.number}"

        assert {:error, {:live_redirect, %{to: ^href}}} = context.result,
               "clicking Open did not navigate to #{href}: #{inspect(context.result)}"

        {:ok, context}
      end

      then_ "the card has a grip to drag by, and Open is not part of it", context do
        {:ok, live, _html} = live(context.conn, ~p"/app/projects/#{context.project.id}/epics")

        assert has_element?(live, "#{context.card} [data-drag-handle]"),
               "the card has no grip, so the whole card is the drag surface"

        refute has_element?(live, "#{context.card} [data-drag-handle] a[data-test='open-story']"),
               "Open sits inside the grip, so clicking it starts a drag"

        {:ok, context}
      end
    end
  end
end
