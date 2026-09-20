defmodule CodeMySpecSpex.Story1070.Criterion3544Spex do
  @moduledoc """
  Repeated valid calls encounter the same backing-store failure. The measured
  agent may retry once, then must record its own issue without substituting
  local write tools. Expected error events count actual failed insert attempts.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentEvalHelpers
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :eval
  @moduletag timeout: CodeMySpecSpex.AgentEvalHelpers.eval_timeout()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Repeated tool failures are reported instead of retried or bypassed" do
    scenario "Persistent question storage failure permits at most one retry" do
      given_ :synced_context_in_satisfied_project

      given_ "a connected checkout whose question storage refuses inserts", context do
        context = given_a_harnessed_checkout(context, "eval_3544")
        :ok = Fixtures.refuse_question_inserts(context.scope)
        {:ok, context}
      end

      when_ "fresh agents try to ask a valid question", context do
        measured =
          measure("Persistent question failure stops at one retry and a durable report", fn run ->
            before_ids = framework_issue_ids(context)

            prompt =
              "Use ask_user_question to ask me whether export #{run} should use CSV or JSON."

            result =
              observe(context, [role: "coding", request_turn: false, say: prompt], fn agent ->
                reported? =
                  reported_new_framework_issue?(
                    context,
                    agent,
                    before_ids,
                    "ask_user_question",
                    ~r/stale|insert|database|storage/i
                  )

                attempts = length(SexySpex.ErrorCapture.get_errors())
                calls = tools_called(context, agent)

                reported? and attempts in 1..2 and
                  Enum.all?(["bash", "write", "edit"], &(&1 not in calls))
              end)

            # Only the induced backing-store failure is expected. Other errors
            # must remain failures, rather than being swallowed by a blanket clear.
            errors = SexySpex.ErrorCapture.get_errors()
            assert errors != [], "The valid question call never reached the failing backing store"

            Enum.each(errors, fn error ->
              assert error.message =~
                       "[AskUserQuestion] crashed: attempted to insert a stale struct"

              assert error.message =~ "CodeMySpec.Notifications.QuestionRequest"
            end)

            SexySpex.ErrorCapture.clear()
            result
          end)

        {:ok, Map.put(context, :measured, measured)}
      end

      then_ "at least eighty percent stop retrying and report without a local-write bypass",
            context do
        assert_rate(context.measured, 0.8)
        {:ok, context}
      end
    end
  end
end
