defmodule CodeMySpecSpex.Story1016.Criterion2083Spex do
  @moduledoc "Story assignment replaces issue work without losing unfinished issues or history."
  use CodeMySpecSpex.Case

  alias CodeMySpec.McpServers.Issues.Tools.AssignIssueToWorkingCopy
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias CodeMySpec.McpServers.Stories.Tools.SetActiveStory
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Assigning a story replaces the entire issue bag", criterion: 2083 do
    scenario "The team switches from two issues to a story" do
      given_ "a staffed copy has two accepted issues and an open issue attempt", ctx do
        ctx = ctx |> Slice.staff() |> Slice.waiting() |> Slice.main_copy()
        issues = for _ <- 1..2, do: Fixtures.issue_fixture(ctx.scope, %{status: :accepted})

        for issue <- issues do
          Slice.call(ctx, AssignIssueToWorkingCopy, %{
            issue_id: issue.id,
            working_copy_id: ctx.scope.active_working_copy_id
          })
        end

        [coder, _qa] = ctx.team

        {_, task} =
          Fixtures.agent_task_fixture(ctx.scope, coder,
            status: :blocked,
            issue_id: hd(issues).id,
            requirement_name: "fix_issue"
          )

        {:ok, Map.merge(ctx, %{issues: issues, attempt: task})}
      end

      when_ "Main assigns the story to the copy", ctx do
        Slice.call(ctx, SetActiveStory, %{
          story_number: ctx.waiting.number,
          working_copy_id: ctx.scope.active_working_copy_id
        })

        {:ok, ctx}
      end

      then_ "the team holds only the story and the unfinished issues remain available", ctx do
        bag =
          Slice.call(ctx, ListIssues, %{
            working_copy_id: ctx.scope.active_working_copy_id,
            severity: "all"
          })

        open = Slice.call(ctx, ListIssues, %{status: "accepted", severity: "all"})

        for issue <- ctx.issues do
          refute bag =~ issue.id
          assert open =~ issue.id
        end

        for member <- ctx.team do
          {:ok, current} = Fixtures.fetch_agent(ctx.scope, member.id)
          assert current.story_id == ctx.waiting.id
          assert current.issue_id == nil
        end

        [coder, _qa] = ctx.team
        {:ok, current} = Fixtures.fetch_agent(ctx.scope, coder.id)
        assert Enum.any?(current.tasks, &(&1.id == ctx.attempt.id and &1.status == :cancelled))
        {:ok, ctx}
      end
    end
  end
end
