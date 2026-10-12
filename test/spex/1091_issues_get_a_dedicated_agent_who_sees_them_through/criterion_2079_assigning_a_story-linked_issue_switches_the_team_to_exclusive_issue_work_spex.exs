defmodule CodeMySpecSpex.Story1091.Criterion2079Spex do
  @moduledoc """
  Story 1091 — Issues get a dedicated agent who sees them through.
  Criterion 2079 — Assigning a story-linked issue switches the team to
  exclusive issue work.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Issues.Tools.AssignIssueToWorkingCopy
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.Stories
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Assigning a story-linked issue switches the team to exclusive issue work",
    criterion: 2079 do
    scenario "a story-linked issue takes the team off its story and its queued reservation" do
      given_ "a team holds a story and has a second story queued behind it", context do
        context = context |> Slice.main_copy() |> Slice.base() |> Slice.child()
        coder = Enum.find(context.team, &(&1.role == :coding))
        qa_agent = Enum.find(context.team, &(&1.role == :qa))
        copy_id = context.scope.active_working_copy_id

        second =
          StoryHelpers.create_story(context.scope,
            title: "Queued behind the active story",
            description: "Reserved on this copy, not yet active."
          )

        {:ok, _} = Stories.reserve_story(context.scope, copy_id, second.id)

        issue =
          Fixtures.issue_fixture(context.scope, %{
            status: :accepted,
            scope: :app,
            severity: :high,
            story_id: context.story.id
          })

        {:ok,
         Map.merge(context, %{
           coder: coder,
           qa_agent: qa_agent,
           second_story_id: second.id,
           issue_id: issue.id
         })}
      end

      when_ "the story-linked issue is assigned to that working copy", context do
        {:reply, assigned, _frame} =
          AssignIssueToWorkingCopy.execute(
            %{issue_id: context.issue_id, working_copy_id: context.scope.active_working_copy_id},
            %Frame{assigns: %{current_scope: context.main_scope, agent_id: context.main.id}}
          )

        refute assigned.isError
        {:ok, context}
      end

      then_ "neither agent has an active story and the copy keeps no reservations", context do
        agents = Agents.list_agents(context.scope)
        coder = Enum.find(agents, &(&1.id == context.coder.id))
        qa_agent = Enum.find(agents, &(&1.id == context.qa_agent.id))

        assert coder.story_id == nil
        assert qa_agent.story_id == nil

        reservations = Stories.list_story_working_copy_ids(context.scope)
        refute Map.has_key?(reservations, context.story.id)
        refute Map.has_key?(reservations, context.second_story_id)
        {:ok, context}
      end

      then_ "both agents prioritize the issue and the coder is offered its fix", context do
        agents = Agents.list_agents(context.scope)
        coder = Enum.find(agents, &(&1.id == context.coder.id))
        qa_agent = Enum.find(agents, &(&1.id == context.qa_agent.id))

        assert coder.issue_id == context.issue_id
        assert qa_agent.issue_id == context.issue_id

        {:reply, offer, _frame} =
          GetNextRequirement.execute(%{}, %Frame{
            assigns: %{current_scope: context.scope, agent_id: context.coder.id}
          })

        refute offer.isError
        text = response_text(offer)
        assert text =~ "entity_type=`issue`"
        assert text =~ "entity_id=`#{context.issue_id}`"
        refute text =~ "entity_type=`component`"
        {:ok, context}
      end
    end
  end
end
