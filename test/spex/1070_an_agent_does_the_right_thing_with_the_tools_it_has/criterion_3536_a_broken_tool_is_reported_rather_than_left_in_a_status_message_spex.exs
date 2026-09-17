defmodule CodeMySpecSpex.Story1070.Criterion3536Spex do
  @moduledoc """
  Story 1070 — An agent does the right thing with the tools it has.
  Criterion 3536 — A broken tool is reported rather than left in a status
  message.

  Rule: An agent files a framework issue when the tooling is what is broken.

  Telling the operator and filing the issue are not alternatives, and treating
  them as alternatives is how findings evaporate.

  A message is addressed to whoever is reading right now, and on 2026-09-15
  nobody was: a main agent sat blocked on unanswered questions for nearly two
  days while its agents reported into a conversation no one opened. An issue
  outlives the session, appears in a listing, and gates a requirement. The
  message is courtesy; the issue is the record.

  So this criterion asserts both, and the `filed_at?/2` half is the one that
  matters — "it also files the issue" is the clause an agent satisfies by
  saying something and moving on, and the whole rule turns on it.
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

  spex "An agent files a framework issue when the tooling is what is broken" do
    scenario "A broken tool is reported rather than left in a status message" do
      given_ :synced_context_in_satisfied_project

      given_ "a checkout on the harness, reporting what its agents do", context do
        {:ok, given_a_harnessed_checkout(context, "eval_3536")}
      end

      when_ "the agent hits a tooling failure it cannot work around", context do
        measured =
          measure("A broken tool is reported rather than left in a status message", fn _run ->
            told =
              "Close task 00000000-0000-0000-0000-000000000000 with `evaluate_task`, " <>
                "then tell me how it went."

            observe(context, [role: "coding", wake: false, say: told], fn agent ->
              called?(context, agent, "send_message") and filed_at?(context, "framework")
            end)
          end)

        {:ok, Map.put(context, :measured, measured)}
      end

      then_ "the finding outlives the turn it was found in", context do
        assert_rate(context.measured, 0.8)

        {:ok, context}
      end
    end
  end
end
