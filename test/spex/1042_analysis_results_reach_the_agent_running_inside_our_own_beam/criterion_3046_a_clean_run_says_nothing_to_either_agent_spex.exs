defmodule CodeMySpecSpex.Story1042.Criterion3046Spex do
  @moduledoc """
  Story 1042 — Analysis results reach the agent running inside our own BEAM.
  Criterion 3046 — A clean run says nothing to either agent.

  Rule: The alert is the same one an external agent gets — same content, same
  silences.

  The silences are half the rule and the easier half to lose. `AnalysisAlert`
  declines to announce a green run on the reasoning that "your fix worked" is
  real information and still not worth a line, because a channel that speaks on
  every tool call is one the model learns to skip — and then the red one arrives
  where nobody reads.

  An internal path that gets the alert right and the silence wrong is worse than
  no internal path, because it teaches the agent to ignore the surface before
  the first real finding lands on it.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The alert is the same one an external agent gets — same content, same silences" do
    scenario "A clean run says nothing to either agent" do
      given_ "an analyzer run has landed with no problems", context do
        # Nothing seeded, deliberately. A green run is the absence of findings,
        # not a record saying "clean" — so the premise is an empty tree and the
        # criterion is about what that produces.
        {:ok, Map.put(context, :agent_id, running_agent(context))}
      end

      when_ "an agent running under Alloy makes its next tool call", context do
        {:ok, Map.put(context, :result, Fixtures.run_script("return 7", agent_context(context)))}
      end

      then_ "the result carries no alert", context do
        assert {:ok, text} = context.result

        # On the alert's own signature rather than on the whole answer.
        # `run_script` wraps a return value ("Returned:\n7"), so asserting
        # equality here would be checking the formatter and would go red for a
        # reason that has nothing to do with this criterion — which is exactly
        # the misdirection a red spec must not hand its implementer.
        refute text =~ "failing in this working copy", """
        A clean tree produced an alert anyway. Every tool call in every turn
        pays for this one, and a channel that speaks when there is nothing to
        say is how it stops being read before the first real finding arrives.

        Got: #{inspect(text)}
        """

        {:ok, context}
      end
    end
  end
end
