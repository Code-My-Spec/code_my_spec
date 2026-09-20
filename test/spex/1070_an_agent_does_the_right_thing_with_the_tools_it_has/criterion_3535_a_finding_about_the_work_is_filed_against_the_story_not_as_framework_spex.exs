defmodule CodeMySpecSpex.Story1070.Criterion3535Spex do
  @moduledoc """
  Story 1070 — An agent does the right thing with the tools it has.
  Criterion 3535 — A finding about the work is filed against the story, not as
  framework.

  Rule: An agent files a framework issue when the tooling is what is broken.

  The other side of 3534, and the reason that rule is about *which* backlog
  rather than about filing at all. Both scopes are one argument apart and an
  agent that gets the distinction backwards produces a framework backlog full
  of application defects — which reads as the harness being broken when it is
  not, and hides the ones that are.

  `app` is also where the requirement graph reads from: `story_issues_resolved`
  gates a story on the accepted issues filed against it, so a defect filed as
  `framework` leaves the story looking clean and ships.

  The premise is the ordinary one. An agent doing the work finds a defect in
  the thing it is building, which is the common case — most findings are about
  the application, and `framework` is the exception.
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
    scenario "A finding about the work is filed against the story, not as framework" do
      given_ :synced_context_in_satisfied_project

      given_ "a checkout on the harness, reporting what its agents do", context do
        {:ok, given_a_harnessed_checkout(context, "eval_3535")}
      end

      when_ "the agent has found a defect in the application it is building", context do
        measured =
          measure("A finding about the work is filed against the story, not as framework",
            fn _run ->
              told =
                "While reading the code you found that `Reservations.book/2` crashes " <>
                  "on an empty list instead of returning an error. Record it."

              observe(context, [role: "coding", request_turn: false, say: told], fn _agent ->
                filed_at?(context, "app") and not filed_at?(context, "framework")
              end)
            end)

        {:ok, Map.put(context, :measured, measured)}
      end

      then_ "it lands on the application backlog and not the framework one", context do
        assert_rate(context.measured, 0.8)

        {:ok, context}
      end
    end
  end
end
