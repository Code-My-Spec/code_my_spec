defmodule CodeMySpecSpex.Story964.Criterion2935Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 2935 — The detailed design happens where the code will be written.

  Rule: An approved epic goes to a working copy, and the agent there does its
  detailed design.

  The division of labour John drew, and it corrects an earlier reading of mine
  that had the main agent running the workshop:

  > "It'll get you your six stories and slap those in an epic and then assign
  > those to a working copy and an agent will do the three amigos, and then it
  > will have the full context of the detailed design for that epic."

  The reason is context rather than tidiness. Whoever writes the code should
  have been in the room when the rules were decided, and the main agent working
  at project level has no business holding the detail of six stories it will
  never implement.

  So dispatch hands over the work *and* the design of it: the epic arrives on a
  copy with its stories still needing Three Amigos, not with them already done.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.EpicHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An approved epic goes to a working copy, and the agent there does its detailed design" do
    scenario "The detailed design happens where the code will be written" do
      given_ :synced_context_component

      given_ "an epic I have agreed to build", context do
        context = EpicHelpers.dispatch_one(context, "Six things to build", stories: 2)

        {:ok, context}
      end

      when_ "I look at what the agent on that copy has to do", context do
        # A story in the epic, not the project's own requirements — the Three
        # Amigos is owed on stories, and the project page shows project nodes.
        story_id = hd(context.story_ids)

        {:ok, _live, html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/stories/#{story_id}/requirements"
          )

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the Three Amigos is still owed on the epic's stories", context do
        assert context.html =~
                 ~r/data-requirement="three_amigos_complete"[^>]*data-satisfied="false"/,
               "the epic's stories arrive with their design already done, so the agent " <>
                 "that writes the code was not in the room when the rules were decided — " <>
                 "which is the whole reason the workshop happens on the copy."

        {:ok, context}
      end

      then_ "and the main agent did not do it", context do
        {:ok, _live, epics} = live(context.conn, ~p"/app/projects/#{context.project.id}/epics")

        assert epics =~ "data-test=\"epic-working-copy\"",
               "the epic names no working copy, so there is nobody else it could have " <>
                 "been handed to"

        {:ok, context}
      end
    end
  end
end
