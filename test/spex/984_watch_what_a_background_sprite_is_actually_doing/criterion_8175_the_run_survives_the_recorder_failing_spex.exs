defmodule CodeMySpecSpex.Story984.Criterion8175Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 8175 — The run survives the recorder failing.

  Half of this is now structural rather than tested. The sprite reports a turn
  with a cast and never waits for a reply, so there is no path by which the
  server's recorder can slow, fail or block a turn that has already been
  answered. That is worth more than an assertion: the earlier arrangement wrote
  records inline and a real store failure raised, which 500'd a turn the agent
  had already completed.

  What remains testable here is the half that can still go wrong quietly — the
  operator being shown a conversation that looks whole when turns are missing
  from it. Absence of evidence must not render as evidence of absence.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A broken recorder does not break the run" do
    scenario "The run survives the recorder failing" do
      when_ "a turn is reported while the conversation store cannot be written", context do
        result =
          Fixtures.record_turn_with_broken_store(
            context.scope,
            Fixtures.user_request("keep working"),
            Fixtures.model_response([Fixtures.text_block("Still going.")])
          )

        assert {:error, _} = result,
               "the recorder must report its own failure rather than swallow it"

        {:ok, context}
      end

      then_ "the operator is not shown a conversation that looks complete", context do
        {:ok, view, _html} =
          live(context.conn, Fixtures.agent_conversation_path(context.scope))

        assert has_element?(view, "[data-test='recording-gap']"),
               "expected the conversation to declare that turns are missing rather than appear whole"

        {:ok, context}
      end
    end
  end
end
