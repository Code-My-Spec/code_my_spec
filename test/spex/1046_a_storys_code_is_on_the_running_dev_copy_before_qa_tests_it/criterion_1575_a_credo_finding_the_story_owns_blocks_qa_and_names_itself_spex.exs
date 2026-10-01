defmodule CodeMySpecSpex.Story1046.Criterion1575Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1575 — Promotion is offered only after the story passes QA (failure
  path: a bare analyzer problem, no accepted issue).

  Superseded by 28d72f8a, and this criterion's text needs retiring or
  rewording in the product: `problems_resolved` — the node that held QA on a
  story whose own copy carried a credo/compiler finding — is gone. Analyzer
  findings are the promote gate's job now: `story_promoted` completes only on
  a completed run per source at HEAD on a clean tree, and a credo finding
  blocks there.

  So what this asserts is the new truth: a bare analyzer finding on the
  story's own copy does not hold QA, and no task is offered for a requirement
  that no longer exists.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.Problems
  alias CodeMySpec.Stories
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A credo finding on the story's own copy is the promote gate's, not QA's",
    criterion: 1575 do
    scenario "a story whose only blocker is a credo finding on its own copy is offered QA" do
      given_ "a story with clean specs, no accepted issues, and one credo finding on its own working copy",
             context do
        context = FullSatisfactionFixtures.apply_up_to_analysis(context)
        context = FullSatisfactionFixtures.apply_qa_readiness_transition(context)

        # The story's own copy, as the fixture chain never assigns one — the
        # finding has to land where the removed node used to look.
        story = Stories.get_story(context.scope, context.story.id)

        {:ok, story} =
          Stories.update_story(context.scope, story, %{
            working_copy_id: context.scope.active_working_copy_id
          })

        context = Map.put(context, :story, story)

        # On disk, so a file sync on the way to the graph does not clear the
        # finding as orphaned (`Problems.clear_problems_for_missing_files/2`).
        :ok =
          Environments.write_file(context.environment, "lib/example/widget.ex", """
          defmodule Example.Widget do
            def render, do: :ok
          end
          """)

        {:ok, [problem]} = Problems.create_problems(context.scope, [credo_finding()])

        {:ok, Map.put(context, :problem, problem)}
      end

      when_ "the coding agent asks for its next work", context do
        {:ok, ask_for_next_work(context)}
      end

      then_ "QA is offered, and no task names problems_resolved", context do
        text = response_text(context.response)

        assert text =~ "QaStory",
               "a credo finding no longer holds QA — the promote gate blocks on it. " <>
                 "Got: #{text}"

        refute text =~ "problems_resolved",
               "the requirement is gone; nothing should be offered for it. Got: #{text}"

        {:ok, context}
      end
    end
  end

  defp ask_for_next_work(context) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
    {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
    Map.put(context, :response, response)
  end

  defp credo_finding do
    %{
      severity: :error,
      source_type: :static_analysis,
      source: "credo",
      file_path: "lib/example/widget.ex",
      line: 17,
      message: "Function is too complex",
      category: "readability",
      rule: "Credo.Check.Refactor.CyclomaticComplexity",
      metadata: %{}
    }
  end
end
