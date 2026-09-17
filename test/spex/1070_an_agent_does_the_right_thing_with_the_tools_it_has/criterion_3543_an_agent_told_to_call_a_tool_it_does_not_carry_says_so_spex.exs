defmodule CodeMySpecSpex.Story1070.Criterion3543Spex do
  @moduledoc """
  Story 1070 — An agent does the right thing with the tools it has.
  Criterion 3543 — An agent told to call a tool it does not carry says so.

  Rule: An agent reports a tool that will not work rather than routing around it.

  The behaviour that cost the most on 2026-09-16 when it was absent, and the
  one nothing currently protects.

  Every agent carries nineteen tools directly and can reach the rest through
  `run_script`. Its prompt names all of them, so "call `create_issue`" is an
  ordinary instruction and a direct call to it is an ordinary mistake — the
  server answers "This server has no tool called …", which is the same sentence
  a genuinely missing tool answers with. What the agent does next is the whole
  criterion: reach it the way it is reachable, and say what happened, rather
  than concluding its bindings are broken and standing down. Two agents stood
  down on that sentence, and one lost a day (`23f5544e`).

  Measured against a lower threshold than the claiming criteria on purpose.
  This is recovery from a surprise rather than the ordinary path, and eight in
  ten is an agent that recovers reliably enough to be left alone overnight.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentEvalHelpers
  import CodeMySpecSpex.SharedGivens

  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :eval

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent reports a tool that will not work rather than routing around it" do
    scenario "An agent told to call a tool it does not carry says so" do
      given_ :synced_context_in_satisfied_project

      given_ "a checkout on the harness, reporting what its agents do", context do
        {:ok, given_a_harnessed_checkout(context, "eval_3543")}
      end

      when_ "the agent is told to call a tool that is not on its surface", context do
        measured =
          measure("An agent told to call a tool it does not carry says so", fn _run ->
            told =
              "Record what you find as you go: call `create_issue` with a title " <>
                "and a description. It is in your tool list."

            observe(context, [role: "coding", say: told], fn agent ->
              reached?(context, agent, "create_issue") and
                called?(context, agent, "run_script")
            end)
          end)

        {:ok, Map.put(context, :measured, measured)}
      end

      then_ "it reaches the tool the way it is reachable, rather than standing down",
            context do
        assert_rate(context.measured, 0.8)

        {:ok, context}
      end
    end
  end
end
