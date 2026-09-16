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

  One observation, three requirements, at two grains:

    * `issues_triaged` — the project's, false while anything is untriaged
    * `issues_resolved` — the project's, false while anything accepted is open
    * `story_issues_resolved` — this story's

  Accepting is the act that moves all three at once: it takes the issue out of
  the untriaged queue and puts it into the unresolved one, and the story it is
  attributed to picks it up. A system that settled the project's two and left
  the story's, or the story's and left the project's, satisfies "the graph
  responded to the observation" and is still wrong about the project.

  ## What it observes

  The answers, not `checked_at`. A requirement left behind is one whose
  *verdict* is from before the observation, and a timestamp cannot tell that
  from a row that was correctly re-answered to the same value. This criterion
  is about the answer being wrong, which is the only version an agent can feel.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.{AcceptIssue, CreateIssue}

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "One observation settles every requirement it moves" do
    scenario "an issue at the gating severity is accepted against a story" do
      given_ "a story with an untriaged issue filed against it", context do
        story = create_story(context.scope, title: "The story it is about", description: "one")

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, filed, _frame} =
          CreateIssue.execute(
            %{
              title: "something is wrong on this story",
              description: "filed at the severity the graph gates on",
              severity: "medium",
              story_id: story.id
            },
            frame
          )

        refute filed.isError, inspect(filed)

        before = read_settled_graph(context)

        {:ok,
         context
         |> Map.put(:story_id, story.id)
         |> Map.put(:issue_id, issue_id(filed))
         |> Map.put(:before, before)}
      end

      when_ "the issue is accepted", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, accepted, _frame} =
          AcceptIssue.execute(%{issue_id: context.issue_id}, frame)

        refute accepted.isError, inspect(accepted)

        {:ok, Map.put(context, :after, read_settled_graph(context))}
      end

      then_ "the queue it left is reported empty", context do
        assert satisfaction_of(context.after, "issues_triaged") == true,
               """
               An issue was accepted and `issues_triaged` still reports an
               untriaged queue.

               Accepting is what takes an issue out of that queue. A graph that
               does not notice goes on telling the product agent there is
               triage waiting, and the agent that goes looking finds nothing —
               which is the state this rule exists to make impossible.

               before: #{inspect(satisfaction_of(context.before, "issues_triaged"))}
               after:  #{inspect(satisfaction_of(context.after, "issues_triaged"))}
               """

        {:ok, context}
      end

      then_ "and the queue it joined is reported open", context do
        assert satisfaction_of(context.after, "issues_resolved") == false,
               """
               An issue was accepted and `issues_resolved` still reports
               nothing outstanding.

               This is the half that fails quietly. The same observation moved
               both project requirements, and a system that settled the one it
               knew about leaves this one saying the project is clean while an
               accepted issue sits open against it.

               before: #{inspect(satisfaction_of(context.before, "issues_resolved"))}
               after:  #{inspect(satisfaction_of(context.after, "issues_resolved"))}
               """

        {:ok, context}
      end

      then_ "and the story it was attributed to carries it", context do
        after_story =
          satisfaction_of(context.after, "story_issues_resolved", "story", context.story_id)

        assert after_story == false,
               """
               An accepted issue is open against this story and its
               `story_issues_resolved` still reads satisfied.

               The grain the observation reaches is the point. Settling the
               project's two requirements and leaving the story's is a graph
               that is right about the project and wrong about the work — it
               hands this story to a coding agent with a finding open on it.

               before: #{inspect(satisfaction_of(context.before, "story_issues_resolved", "story", context.story_id))}
               after:  #{inspect(after_story)}
               """

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
