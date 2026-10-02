defmodule CodeMySpecSpex.Story1026.Criterion1654Spex do
  @moduledoc """
  Story 1026 — I approve an epic and it gets built somewhere else.
  Criterion 1654 — Every story card on the epics dashboard, in an epic or
  unfiled, has an Open link to that story's page.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures

  cloud_endpoint()

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Every story card opens its story", criterion: 1654 do
    scenario "one story in an epic and one unfiled" do
      given_ "a story filed in an epic and one that is not", context do
        epic = Fixtures.epic_fixture(context.scope, %{name: "Refunds"})
        filed = Fixtures.authored_story(context.scope, "Refund a paid order")
        :ok = Fixtures.put_story_in_epic(context.scope, filed, epic)
        unfiled = Fixtures.authored_story(context.scope, "Export orders to CSV")

        {:ok, Map.merge(context, %{epic: epic, filed: filed, unfiled: unfiled})}
      end

      when_ "I look at the epics dashboard", context do
        {:ok, live, _html} = live(context.conn, ~p"/app/projects/#{context.project.id}/epics")
        {:ok, Map.put(context, :live, live)}
      end

      then_ "each card has an Open link to its own story's page", context do
        for {card, story} <- [
              {"#epic-#{context.epic.id}-story-#{context.filed.id}", context.filed},
              {"#unassigned-story-#{context.unfiled.id}", context.unfiled}
            ] do
          href = ~p"/app/projects/#{context.project.id}/stories/#{story.number}"

          assert has_element?(context.live, "#{card} a[data-test='open-story'][href='#{href}']"),
                 "the card for #{inspect(story.title)} has no Open link to #{href}"
        end

        {:ok, context}
      end
    end
  end
end
