defmodule CodeMySpecSpex.Story965.Criterion2924Spex do
  @moduledoc """
  Story 965 — A timeline across the top says where my project is.
  Criterion 2924 — A project mid-build shows one step for all of its stories.

  Rule: The steps are the project's own requirements, and all of the story work
  is one of them.

  The distinction the whole story turns on. John, on what `AgentProgressLive`
  got wrong: *"it was trying to represent the non-linear story work in a linear
  process."* A project's own requirements are a sequence — you cannot triage
  issues that do not exist yet — so they can be a timeline. Eleven stories being
  built are not a sequence, and drawing them as one is a lie that gets worse the
  more stories there are.

  So the story work is a single step however many stories are behind it, and the
  graph keeps its per-story detail for the page that wants it.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.MainAgentHelpers
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  # The timeline rides the main agent's conversation, and there is no main agent
  # without somewhere to run it — `ensure_main_agent/1` refuses with
  # `:not_connected`. Same reason story 963's criteria connect one.
  setup %{scope: scope} do
    Fixtures.connect_provider(scope, :openai)
    :ok
  end

  spex "The steps are the project's own requirements, and all of the story work is one of them" do
    scenario "A project mid-build shows one step for all of its stories" do
      given_ "a project with its own agent", context do
        {:ok, given_a_main_checkout(context, "spex_timeline")}
      end

      given_ :synced_context_component
      given_ :story_linked_to_component

      given_ "a second story, so there is more than one to collapse", context do
        # Through the same MCP tools the first one used. Two is enough: the
        # claim is that the count does not change the timeline, and one story
        # cannot tell "one step per story" from "one step for all of them".
        second =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "A second thing to build",
            description: "So the timeline has more than one story behind its step",
            acceptance_criteria: ["It is built"]
          )

        {:ok, Map.put(context, :second_story, second)}
      end

      when_ "I look at the timeline", context do
        {:ok, _live, html} = live(context.conn, main_conversation_path(context))

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the story work is one step, not one per story", context do
        steps =
          Regex.scan(~r/data-test="timeline-step"[^>]*data-step="work_dispatched"/, context.html)

        assert length(steps) == 1,
               "the timeline draws #{length(steps)} story-work steps for a project with " <>
                 "two stories. One per story makes the timeline grow with the backlog, " <>
                 "and puts non-linear work on a line."

        {:ok, context}
      end

      then_ "and the whole timeline is the project's own requirements", context do
        assert context.html =~ "data-test=\"project-timeline\"",
               "there is no timeline on the page"

        assert context.html =~ "data-test=\"timeline-step\"",
               "the timeline has no steps in it"

        {:ok, context}
      end
    end
  end
end
