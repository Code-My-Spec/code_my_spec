defmodule CodeMySpecSpex.Story1042.Criterion3044Spex do
  @moduledoc """
  Story 1042 — Analysis results reach the agent running inside our own BEAM.
  Criterion 3044 — An Alloy agent is told its own turn broke something.

  Rule: The agent is told what its working copy's analyzers found, without
  having asked.

  The external half of this shipped: `Hooks.AnalysisAlert` names the analyzer,
  the count and the age, and `Hooks.PostToolUse` puts it on the next tool
  result. An agent running under Alloy fires no `PostToolUse`, so none of that
  reaches it — story 890 was written "As an agent" and built for the one kind of
  agent that has hooks.

  ## What is premise and what is under test

  The problems are seeded. How a finding comes to exist is `Analysis`'s job and
  another story's subject; what this criterion is about is whether the agent is
  *told*. So the run landing is the Given, and the alert on the tool result is
  the Then.

  The agent is real. `running_agent/1` goes through `CmsHarness.Agents.launch/1`
  — the same call the server makes over the channel — and the tool call is the
  one it carries, executed against its own session. Nothing here stands in for
  the surface the criterion is about.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The agent is told what its working copy's analyzers found, without having asked" do
    scenario "An Alloy agent is told its own turn broke something" do
      given_ "an agent running under Alloy on a working copy", context do
        {:ok, Map.put(context, :agent_id, running_agent(context))}
      end

      given_ "an analyzer run for that copy has landed with problems", context do
        Fixtures.problem_fixture(context.scope, %{
          source: "compiler",
          message: "** (SyntaxError) missing terminator: end",
          file_path: "lib/example_context.ex"
        })

        {:ok, context}
      end

      when_ "the agent makes its next tool call", context do
        {:ok, Map.put(context, :result, Fixtures.run_script("return 1", agent_context(context)))}
      end

      then_ "the result carries the alert", context do
        assert {:ok, text} = context.result

        assert text =~ "compiler",
               """
               The agent called a tool with a broken tree behind it and was told
               nothing. An external agent in the same position gets the alert on
               its next tool call; this one finds out at some later turn, or
               never — which is the failure story 890 was written about,
               surviving in the half of the product that story could not see.

               Got: #{inspect(text)}
               """

        assert text =~ "failing in this working copy"

        {:ok, context}
      end

      then_ "and the agent asked for nothing", context do
        # The script called no tool and requested no findings — it returns a
        # constant. So anything about the analyzers in that answer arrived
        # because the orchestrator put it there, which is what "without having
        # asked" means.
        assert {:ok, text} = context.result

        assert text =~ "list_problems",
               "the alert names no way to get the detail, so being told costs a guess"

        {:ok, context}
      end
    end
  end
end
