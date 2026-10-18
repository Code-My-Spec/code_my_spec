defmodule CodeMySpecSpex.Story1091.Criterion2080Spex do
  @moduledoc """
  Story 1091 — Issues get a dedicated agent who sees them through.
  Criterion 2080 — Assigning a project issue clears story work for the
  whole team.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias CodeMySpec.Agents
  alias CodeMySpec.Stories
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Assigning a project issue clears story work for the whole team", criterion: 2080 do
    scenario "a project issue with no story of its own still frees both teammates" do
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
            severity: :high
          })

        {:ok,
         Map.merge(context, %{
           coder: coder,
           qa_agent: qa_agent,
           second_story_id: second.id,
           issue_id: issue.id
         })}
      end

      when_ "the project-level issue, unlinked to any story, is assigned to that working copy",
            context do
        assigned =
          ToolLibrary.run(
            "assign_issue_to_working_copy",
            %{issue_id: context.issue_id, working_copy_id: context.scope.active_working_copy_id},
            %{scope: context.main_scope, agent_id: context.main.id}
          )

        assert match?({:ok, _}, assigned)
        {:ok, context}
      end

      then_ "the team's active story IDs and the copy's reservations are all cleared", context do
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

      then_ "the issue is assigned to the copy and becomes the whole team's active issue",
            context do
        bag =
          ToolLibrary.run(
            "list_issues",
            %{
              working_copy_id: context.scope.active_working_copy_id,
              status: "all",
              severity: "all"
            },
            %{scope: context.main_scope, agent_id: context.main.id}
          )

        assert match?({:ok, _}, bag)
        assert response_text(bag) =~ context.issue_id

        agents = Agents.list_agents(context.scope)
        coder = Enum.find(agents, &(&1.id == context.coder.id))
        qa_agent = Enum.find(agents, &(&1.id == context.qa_agent.id))

        assert coder.issue_id == context.issue_id
        assert qa_agent.issue_id == context.issue_id
        {:ok, context}
      end
    end
  end
end
