defmodule CodeMySpecSpex.Story1070.Criterion3540Spex do
  @moduledoc """
  Story 1070 — An agent does the right thing with the tools it has.
  Criterion 3540 — An agent that finishes work closes the task.

  Rule: An agent closes the work it finished.

  The other end of 3539, and the one that costs more when it is missing. An
  open task is what the harness evaluates: the stop hook checks the output, the
  graph learns the requirement moved, and the next agent is offered something
  else. An agent that does the work and walks away leaves the requirement
  looking untouched and the task looking abandoned, which is the state four
  tasks sat in on 2026-09-16.

  Closing before taking more is the second half and is separately assertable.
  An agent holding two open tasks has told the graph it is doing two things and
  can finish at most one of them, so the ordering is the claim rather than the
  presence of both calls.
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

  spex "An agent closes the work it finished" do
    scenario "An agent that finishes work closes the task" do
      given_ :synced_context_in_satisfied_project

      given_ "a checkout on the harness, reporting what its agents do", context do
        {:ok, given_a_harnessed_checkout(context, "eval_3540")}
      end

      when_ "a fresh agent works what the graph offers it", context do
        measured =
          measure("An agent that finishes work closes the task", fn _run ->
            observe(context, [role: "coding"], fn agent ->
              closed_before_taking_more?(context, agent)
            end)
          end)

        {:ok, Map.put(context, :measured, measured)}
      end

      then_ "it closes what it took, before taking anything else", context do
        assert_rate(context.measured, 0.9)

        {:ok, context}
      end
    end
  end
end
