defmodule CodeMySpecSpex.Story1016.Criterion2084Spex do
  @moduledoc "A refused switch leaves issue work assigned."
  use CodeMySpecSpex.Case

  alias CodeMySpec.McpServers.Stories.Tools.SetActiveStory
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Refused story assignment preserves the issue bag", criterion: 2084 do
    scenario "An unknown story cannot displace issue work" do
      given_ "a team has an assigned issue", ctx do
        ctx = Slice.staff(ctx)
        issue = Fixtures.issue_fixture(ctx.scope, %{status: :accepted})

        Slice.call(ctx, "assign_issue_to_working_copy", %{
          issue_id: issue.id,
          working_copy_id: ctx.scope.active_working_copy_id
        })

        {:ok, Map.put(ctx, :issue, issue)}
      end

      when_ "Main attempts to assign an unknown story", ctx do
        assert {true, _} =
                 Slice.attempt(ctx, SetActiveStory, %{
                   story_number: -1,
                   working_copy_id: ctx.scope.active_working_copy_id
                 })

        {:ok, ctx}
      end

      then_ "the bag and active issue are unchanged", ctx do
        bag =
          Slice.call(ctx, "list_issues", %{
            working_copy_id: ctx.scope.active_working_copy_id,
            severity: "all"
          })

        assert bag =~ ctx.issue.id

        for member <- ctx.team do
          {:ok, current} = Fixtures.fetch_agent(ctx.scope, member.id)
          assert current.issue_id == ctx.issue.id
          assert current.story_id == nil
        end

        {:ok, ctx}
      end
    end
  end
end
