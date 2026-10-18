defmodule CodeMySpecSpex.Story1062.Criterion3493Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3493 — A requirement the observation moved is not left carrying the
  old answer.

  Rule: an observation settles every requirement it moves, or it is recomputed
  instead.

  ## The correctness floor the cost rules trade against

  Every other rule on this story bounds work: recompute what moved, leave the
  rest, collapse a burst. This is the one that says what "what moved" has to
  cover, and it is the rule the rest are only safe on top of.

  The failure it names is specific to applying observations rather than
  re-deriving from them. A pass that recomputes an entity answers *every*
  requirement that entity carries, so a requirement cannot be missed. A system
  that applies an observation answers the ones it knows about, and the ones it
  does not keep whatever they already said — with nothing left to correct them,
  because the observation has been consumed.

  Measured three times while this was being built, each time by comparing an
  applied projection against a recomputed one:

    * a story created after the seed never projected at all — three rows
      `missing`, because settling a requirement updates rows and does not write
      them;
    * a sealed story left `three_amigos_complete` reading unsealed — one row
      `disagree`, because the story-row observation was applied and nothing
      settled that requirement;
    * a file sync left four project rollups behind — the observation moved
      `spex_boundary_ready`, `qa_integration_plan`, `personas_complete` and
      `architecture_designed`, and settled none of them.

  All three are invisible from inside the applying system. It did what it knew
  how to do and reported success.

  ## Why an accepted issue

  Acceptance clears this story's triage gate and introduces an unsatisfied
  issue submission node feeding story readiness. The separate project issue
  branch stays unchanged: story work is not copied into that bag.

  ## What it observes

  The answers, not `checked_at`. A requirement left behind is one whose
  *verdict* is from before the observation, and a timestamp cannot tell that
  from a row that was correctly re-answered to the same value. This criterion
  is about the answer being wrong, which is the only version an agent can feel.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "One observation settles every requirement it moves", criterion: 1410 do
    scenario "an issue at the gating severity is accepted against a story" do
      given_ "a story with an untriaged issue filed against it", context do
        story = create_story(context.scope, title: "The story it is about", description: "one")

        frame = %Frame{assigns: %{current_scope: context.scope}}

        filed =
          ToolLibrary.run(
            "create_issue",
            %{
              title: "something is wrong on this story",
              description: "filed at the severity the graph gates on",
              severity: "medium",
              story_number: story.number
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, filed), inspect(filed)

        before = read_settled_graph(context)

        {:ok,
         context
         |> Map.put(:story_id, story.id)
         |> Map.put(:issue_id, issue_id(filed))
         |> Map.put(:before, before)}
      end

      when_ "the issue is accepted", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        accepted =
          ToolLibrary.run(
            "accept_issue",
            %{issue_id: context.issue_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, accepted), inspect(accepted)

        {:ok, Map.put(context, :after, read_settled_graph(context))}
      end

      then_ "the story's triage queue is reported empty", context do
        assert satisfaction_of(context.after, "story_issues_triaged", "story", context.story_id) ==
                 true

        assert satisfaction_of(context.before, "story_issues_triaged", "story", context.story_id) ==
                 false

        {:ok, context}
      end

      then_ "the accepted issue introduces its unfinished submission", context do
        assert satisfaction_of(context.after, "submitted", "issue", context.issue_id) == false

        refute Enum.any?(
                 context.before["nodes"],
                 &(&1["entity_type"] == "issue" and &1["entity_id"] == context.issue_id)
               )

        {:ok, context}
      end

      then_ "the project rollup includes the work without assigning it separately", context do
        assert satisfaction_of(context.before, "issues_resolved") == true
        assert satisfaction_of(context.after, "issues_resolved") == false

        refute Enum.any?(
                 context.after["nodes"],
                 &(&1["entity_type"] == "issue" and &1["entity_id"] == context.issue_id and
                     &1["name"] in ["assigned", "completed"])
               )

        {:ok, context}
      end
    end
  end

  # `create_issue` answers "Issue created: … (ID: …)" and that id is what
  # `accept_issue` takes. Read off the response rather than queried back, so the
  # spex holds the issue by the same handle an agent does.
  defp issue_id(response) do
    text = response_text(response)
    [_, id] = Regex.run(~r/\(ID: ([^)]+)\)/, text) || flunk("no issue id in: #{text}")
    String.trim(id)
  end
end
