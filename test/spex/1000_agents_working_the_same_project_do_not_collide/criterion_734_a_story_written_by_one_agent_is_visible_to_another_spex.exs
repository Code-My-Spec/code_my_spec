defmodule CodeMySpecSpex.Story1000.Criterion734Spex do
  @moduledoc """
  Story 1000 — Agents working the same project do not collide.
  Criterion 734 — A story written by one agent is visible to another.

  Rule: Authored work is shared by every agent on the project.

  The counterweight to the separation rules. Files, problems and components are
  projections of a working copy and belong to one agent; stories, criteria and
  the architecture are *authored*, and belong to the project. Getting this
  backwards in either direction breaks the tool: shared projections mean agents
  blocking each other on work they never did, and per-agent authored work means
  two agents building different applications.

  Surface: the MCP tools, because writing and reading stories is what an agent
  actually does. Both calls go through the same project scope — which is the
  claim: authorship is not partitioned by working copy.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.{CreateStory, ListStories, UpdateStory}

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Authored work belongs to the project" do
    scenario "A story written by one agent is visible to another" do
      given_ "two agents are serving the same project", context do
        # Two working copies, one project. What differs is the harness on the
        # scope; the project does not.
        first = context.scope
        second = %{context.scope | active_harness_id: Ecto.UUID.generate()}

        {:ok, context |> Map.put(:first_agent, first) |> Map.put(:second_agent, second)}
      end

      when_ "one agent creates a story with acceptance criteria", context do
        {:reply, response, _frame} =
          CreateStory.execute(
            %{
              title: "Bookings show up on a calendar",
              description:
                "As a salon owner, I want today's bookings on a calendar, so that I know who is coming in.",
              acceptance_criteria: ["The calendar shows today by default"]
            },
            %Frame{assigns: %{current_scope: context.first_agent}}
          )

        refute response.isError,
               "the first agent could not author a story: #{response_text(response)}"

        text = response_text(response)
        [_, story_id] = Regex.run(~r/\(ID: (\d+)\)/, text)

        # Released into the backlog by the same agent, because only a
        # `ready_for_dev` story projects into the requirement graph — a draft is
        # authored but not yet work, and offering it would surface a story its
        # author is still writing. Marking it ready is part of authoring it, so
        # it belongs in this `when_` rather than in a fixture.
        {:reply, released, _frame} =
          UpdateStory.execute(
            %{story_id: story_id, ready_for_dev: true},
            %Frame{assigns: %{current_scope: context.first_agent}}
          )

        refute released.isError,
               "the first agent could not release its own story: #{response_text(released)}"

        {:ok, context |> Map.put(:create_response, response) |> Map.put(:story_id, story_id)}
      end

      then_ "the other agent sees that story and its criteria", context do
        {:reply, response, _frame} =
          ListStories.execute(%{}, %Frame{assigns: %{current_scope: context.second_agent}})

        text = response_text(response)

        assert text =~ "Bookings show up on a calendar",
               "a story authored by one agent was invisible to another on the same project. " <>
                 "Authored work is the project's, not the working copy's — partitioning it " <>
                 "means two agents building different applications. Got: #{text}"

        {:ok, context}
      end

      then_ "the requirement graph offers the same authored work to both", context do
        first_view = story_requirements(context.first_agent)
        second_view = story_requirements(context.second_agent)

        # Anchor: the graph answered about story work at all, so the equality
        # below is comparing something rather than two empty strings.
        assert first_view =~ "story" or first_view =~ "Story",
               "the graph returned no story-scoped work for the agent that authored one: " <>
                 first_view

        assert first_view == second_view,
               "the graph offered different authored work to two agents on one project. " <>
                 "Neither has any files here, so the only thing that could differ is the " <>
                 "authored work — which belongs to the project, not the working copy.\n\n" <>
                 "wrote it:  #{first_view}\n\nthe other: #{second_view}"

        {:ok, context}
      end
    end
  end

  defp story_requirements(scope) do
    alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements

    {:reply, response, _frame} =
      ListRequirements.execute(%{entity_type: "story", summary: false}, %Frame{
        assigns: %{current_scope: scope}
      })

    response_text(response)
  end
end
