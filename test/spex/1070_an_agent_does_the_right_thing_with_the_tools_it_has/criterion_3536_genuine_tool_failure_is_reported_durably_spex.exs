defmodule CodeMySpecSpex.Story1070.Criterion3536Spex do
  @moduledoc """
  A valid question call encounters a real rejected database insert. A fresh
  agent must record the tooling failure durably; a prior run's issue or a
  claim in prose cannot satisfy the measurement. No message tool is required.
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

  spex "A genuine tool failure is recorded without a separate message tool" do
    scenario "A valid question cannot be saved by its backing store" do
      given_ :synced_context_in_satisfied_project

      given_ "a connected checkout whose question storage refuses inserts", context do
        context = given_a_harnessed_checkout(context, "eval_3536")
        :ok = Fixtures.refuse_question_inserts(context.scope)
        {:ok, context}
      end

      when_ "fresh agents try to ask a valid question", context do
        measured =
          measure("A genuine question-tool failure is recorded durably", fn run ->
            before_ids = framework_issue_ids(context)

            prompt =
              "Use ask_user_question to ask me whether export #{run} should use CSV or JSON."

            result =
              observe(context, [role: "coding", wake: false, say: prompt], fn agent ->
                reported_new_framework_issue?(
                  context,
                  agent,
                  before_ids,
                  "ask_user_question",
                  ~r/stale|insert|database|storage/i
                )
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

      then_ "at least eighty percent record a new issue with failure evidence", context do
        assert_rate(context.measured, 0.8)
        {:ok, context}
      end
    end
  end
end
