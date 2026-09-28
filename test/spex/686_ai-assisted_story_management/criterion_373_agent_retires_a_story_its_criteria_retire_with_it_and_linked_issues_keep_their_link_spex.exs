defmodule CodeMySpecSpex.Story686.Criterion373Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 373 — Agent retires a story; it leaves the backlog and the graph,
  its criteria retire with it, and linked issues keep their link.

  Covers Rule "The agent can create, read, update, and retire stories within
  the active project." Nothing is deleted: the story keeps its row and
  number, so a spec directory or issue naming it never points at another.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Issues.Tools.GetIssue
  alias CodeMySpecSpex.CriterionScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Retiring a story keeps it, its criteria and its issues", criterion: 373 do
    scenario "a story with a criterion and a linked issue is retired" do
      given_ "a story with a criterion and a linked issue, beside a sibling story", context do
        sibling = CriterionScript.create_story(context.scope, "Sibling story", [])
        story = CriterionScript.create_story(context.scope, "Retiring story", ["A thing happens"])
        [number] = context.scope |> CriterionScript.story_text(story) |> CriterionScript.numbers()

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, issue_response, _frame} =
          CreateIssue.execute(
            %{
              title: "Onboarding step is confusing",
              severity: "medium",
              description: "User reported the step copy was unclear.",
              story_id: story
            },
            frame
          )

        [_, issue_id] = Regex.run(~r/\(ID:\s*([^\)\s]+)\)/, response_text(issue_response))

        {:ok, Map.merge(context, %{story: story, sibling: sibling, number: number, issue_id: issue_id})}
      end

      when_ "the agent retires the story", context do
        result = CriterionScript.run(context.scope, "return retire_story({ story_id = \"#{context.story}\" })")
        refute result.error?, "retire_story failed: #{result.text}"
        {:ok, context}
      end

      then_ "it leaves the backlog, and the sibling stays", context do
        text = CriterionScript.run(context.scope, "return list_story_titles({})").text

        assert text =~ "Sibling story", "anchor: the sibling should still be listed. Got: #{text}"
        refute text =~ "Retiring story", "the retired story is still in the backlog. Got: #{text}"

        {:ok, context}
      end

      and_ "its criterion is retired and still readable by its number", context do
        text =
          CriterionScript.run(context.scope, "return get_criterion({ criterion_id = \"#{context.number}\" })").text

        assert text =~ "A thing happens", "criterion #{context.number} should still be readable. Got: #{text}"
        assert text =~ ~r/retired/i, "criterion #{context.number} should be retired. Got: #{text}"

        {:ok, context}
      end

      and_ "the issue keeps its link to the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetIssue.execute(%{issue_id: context.issue_id}, frame)
        body = response_text(response)

        assert body =~ "Onboarding step is confusing"
        assert body =~ "**Story:** #{context.story}", "the issue lost its story link. Got: #{body}"

        {:ok, context}
      end
    end
  end
end
