defmodule CodeMySpecSpex.Story983.Criterion8167Spex do
  @moduledoc """
  Story 983 — Spec failures block only stories whose specs have gone green
  Criterion 8167 — The agent is handed the specs-passing task rather than
  QA.

  Rule: QA cannot begin on a story until its specs are ready.

  The node's position in the chain. `bab2f792` retargeted the component
  terminals straight at `qa_complete`; restoring `bdd_specs_passing` puts
  a gate back between them, so a story cannot reach a QA sub-agent before
  its own contract is green.

  Surface: `show_story_requirements` MCP tool. The story-scoped view is
  the honest surface here — project-wide `get_next_requirement` answers
  with whatever the global frontier happens to be, which is a fact about
  the rest of the project rather than about this story's ordering.

  Both halves are asserted: the gate is open work, and QA behind it is
  not yet reachable.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.ShowStoryRequirements

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "The specs-passing gate sits in front of QA" do
    scenario "The agent is handed the specs-passing task rather than QA" do
      given_ :synced_context_component
      given_ :story_linked_to_component

      given_ "the story's specs are not ready — no green run has ever landed",
             context do
        {:ok, context}
      end

      when_ "the agent asks what the story needs", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ShowStoryRequirements.execute(%{story: to_string(context.story.id)}, frame)

        refute response.isError,
               "expected show_story_requirements to succeed, got: #{inspect(response)}"

        {:ok, Map.put(context, :requirements_body, response_text(response))}
      end

      then_ "the specs-passing requirement is open work on the story", context do
        assert context.requirements_body =~ ~r/\[ \]\s+\*\*bdd_specs_passing\*\*/,
               "expected the specs-passing gate to be unsatisfied, got: #{context.requirements_body}"

        {:ok, context}
      end

      then_ "the QA requirement is not yet actionable", context do
        body = context.requirements_body

        # Anchor: qa_complete is on the story at all, so the assertion
        # below is about its state rather than its absence.
        assert body =~ "qa_complete",
               "expected qa_complete to be listed on the story, got: #{body}"

        assert body =~ ~r/\[ \]\s+\*\*qa_complete\*\*/,
               "QA must stay unsatisfied while the specs-passing gate is closed, got: #{body}"

        # Ordering is the criterion: the gate is listed before QA, so the
        # agent walking the story meets it first.
        gate_at = :binary.match(body, "bdd_specs_passing") |> elem(0)
        qa_at = :binary.match(body, "qa_complete") |> elem(0)

        assert gate_at < qa_at,
               "the specs-passing gate must come before qa_complete on the story, got: #{body}"

        {:ok, context}
      end
    end
  end
end
