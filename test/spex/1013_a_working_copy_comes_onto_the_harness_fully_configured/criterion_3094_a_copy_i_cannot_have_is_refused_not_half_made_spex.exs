defmodule CodeMySpecSpex.Story1013.Criterion3094Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 3094 — A copy I cannot have is refused, not half-made.

  Rule: An agent asks for a working copy and gets one it can work in.

  The failure surface of asking, and the one that matters because of where the
  work happens. The harness makes the checkout on its own disk; the server owns
  the record. A project with no harness anywhere has nobody to make it, and the
  wrong thing to do is write the row and let the directory follow later.

  This project already knows what that costs. `WorkingCopies.ensure_default/1`
  mints a rootless nil-object row, and `EpicDispatch` had to grow a guard
  against sending an epic there — the page said "Being built on your project's
  checkout" about a directory that does not exist. A row that describes a
  checkout nobody made is not a smaller version of a working copy; it is a lie
  that every consumer downstream believes.

  ## Not the same as an epic with nowhere to go

  `EpicDispatch.approve/2` deliberately dispatches an epic even when there is no
  checkout — *"the decision was the user's and it stands"* — and reports it as
  waiting. That is right, and it is a different act: agreeing to build something
  is a decision that survives having nowhere to build it. Asking for a checkout
  is a request for a thing, and a request that cannot be satisfied is refused.

  ## Red on purpose

  `CreateWorkingCopy` does not exist.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.CreateWorkingCopy
  alias CodeMySpec.WorkingCopies

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent asks for a working copy and gets one it can work in" do
    scenario "A copy I cannot have is refused, not half-made" do
      given_ "a project with no harness running anywhere", context do
        before = WorkingCopies.list_harnesses(context.scope)

        {:ok, Map.put(context, :before, length(before))}
      end

      when_ "an agent asks for a working copy", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CreateWorkingCopy.execute(%{label: "nowhere to put it"}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it is told no machine can host one", context do
        text = response_text(context.response)

        assert text =~ ~r/harness|machine/i,
               "the refusal does not say what is missing, so the agent cannot act " <>
                 "on it. Got: #{text}"

        {:ok, context}
      end

      then_ "and no row is written for a checkout that does not exist", context do
        after_count = length(WorkingCopies.list_harnesses(context.scope))

        assert after_count == context.before,
               "a working copy was recorded that nothing made. A row describing a " <>
                 "checkout nobody created is not a smaller working copy — it is one " <>
                 "every consumer downstream believes in."

        {:ok, context}
      end
    end
  end
end
