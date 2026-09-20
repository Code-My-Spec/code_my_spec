defmodule CodeMySpecSpex.Story561.Criterion3606Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3606 — Unavailable scope does not fall back to the project

  ## What "unavailable" means, and what it stopped meaning

  This asserted that a copy with no *active story* answered `unavailable`. That
  is no longer the rule: a copy without a selection answers for its own scope —
  the project's requirements plus the stories assigned to it — because project
  requirements belong to no story and would otherwise reach nobody.

  The criterion survives that change intact, because the scope it is about was
  never the one with no selection. A session with **no working copy on this
  project** has nothing to answer for, and answering it with the project's work
  would hand an agent a queue it has no checkout to build in.

  The other half is unchanged and is the half the title names: asking by id for
  another copy's story, or for a story in another project, widens nothing.
  """
  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Stories.Tools.SetActiveStory
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  alias CodeMySpecSpex.TaskResponseHelpers
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Unavailable scope does not fall back to the project" do
    scenario "Unavailable scope does not fall back to the project" do
      given_ "a session with no working copy, beside another copy's story and a foreign one",
             context do
        context = context |> Slice.base() |> Slice.child() |> Slice.waiting()
        other_scope = CodeMySpecSpex.Fixtures.live_agent_scope(context.scope)

        Slice.call(
          %{context | scope: other_scope},
          SetActiveStory,
          %{story_id: to_string(context.waiting.id)}
        )

        project = CodeMySpecSpex.Fixtures.project_fixture(context.scope)
        foreign_scope = %{context.scope | active_project: project, active_project_id: project.id}

        foreign =
          CodeMySpecSpex.StoryHelpers.create_story(foreign_scope,
            title: "Foreign project story",
            description: "Not work for this project",
            acceptance_criteria: []
          )

        {:ok, Map.put(context, :foreign, foreign)}
      end

      when_ "the agent asks what to work on", context do
        # Three ways of asking, all from a session that names no checkout: for
        # whatever is next, for another copy's story by id, and for a story in
        # another project by id.
        rootless = %{context.scope | active_working_copy_id: nil}

        answers =
          Enum.map(
            [
              %{},
              %{story_id: to_string(context.waiting.id)},
              %{story_id: to_string(context.foreign.id)}
            ],
            fn params ->
              frame = %Frame{assigns: %{current_scope: rootless}}

              {:reply, response, _frame} =
                GetNextRequirement.execute(params, frame)

              TaskResponseHelpers.response_text(response)
            end
          )

        {:ok, Map.put(context, :answers, answers)}
      end

      then_ "nothing is offered and the project's own work is not consulted", context do
        Enum.each(context.answers, fn answer ->
          assert answer =~ "Status: unavailable"
          refute answer =~ "requirement_name=`"
          refute Slice.offered?(answer, context.waiting.id)
          refute Slice.offered?(answer, context.foreign.id)
          refute Slice.offered?(answer, Slice.component(context, "Reservations.Booking").id)
        end)

        {:ok, context}
      end
    end
  end
end
