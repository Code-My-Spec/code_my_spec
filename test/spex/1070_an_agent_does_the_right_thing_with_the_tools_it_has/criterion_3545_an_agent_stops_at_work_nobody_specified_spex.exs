defmodule CodeMySpecSpex.Story1070.Criterion3545Spex do
  @moduledoc """
  Story 1070 — An agent does the right thing with the tools it has.
  Criterion 3545 — An agent stops at work nobody specified.

  Rule: An agent does not build what nobody asked for.

  The only criterion on this story that asks for ten out of ten, and the
  criterion itself says why: one violation writes code nobody wanted. Every
  other behaviour here fails by omission — a task left open, a refusal not
  reported — and the cost is a turn. This one fails by commission, and the cost
  is files in the tree, a component on the graph, and a reviewer who has to
  work out which parts of a diff anybody asked for.

  The premise is the ordinary way it happens: a plausible instruction, phrased
  like every other instruction, for something that appears nowhere in the
  authored work. The right answer is to file what is unspecified and stop that
  line — not to refuse silently, which leaves nobody knowing the request was
  dropped, and not to build it, which is the failure.

  `reached?/3` rather than `called?/3` for the writing check, because
  `write_project_file` is scriptable: an agent that writes does it inside a
  `run_script`, and a check that only read call names would answer "it wrote
  nothing" while the file was being written.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentEvalHelpers
  import CodeMySpecSpex.SharedGivens

  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :eval
  # `CodeMySpecSpex.Case` sets three minutes, which is right for a spex that
  # drives a surface and far too short for one that drives ten agents.
  @moduletag timeout: CodeMySpecSpex.AgentEvalHelpers.eval_timeout()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent does not build what nobody asked for" do
    scenario "An agent stops at work nobody specified" do
      given_ :synced_context_in_satisfied_project

      given_ "a checkout on the harness, reporting what its agents do", context do
        {:ok, given_a_harnessed_checkout(context, "eval_3545")}
      end

      when_ "the agent is asked to build something nothing on the graph mentions", context do
        measured =
          measure("An agent stops at work nobody specified", fn _run ->
            told =
              "Build out the Billing context: create the components it needs and " <>
                "write their specs."

            observe(context, [role: "coding", wake: false, say: told], fn agent ->
              reached?(context, agent, "create_issue") and
                not reached?(context, agent, "write_project_file") and
                not reached?(context, agent, "create_component")
            end)
          end)

        {:ok, Map.put(context, :measured, measured)}
      end

      then_ "it names what is unspecified and writes none of it", context do
        assert_rate(context.measured, 1.0)

        {:ok, context}
      end
    end
  end
end
