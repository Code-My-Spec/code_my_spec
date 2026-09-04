defmodule CodeMySpecSpex.Story1013.Criterion3101Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 3101 — A half that fails does not leave the other half standing.

  Rule: The harness does the work on disk and the server does the work on the
  record, and the caller makes one call.

  Two halves in two places cannot be made atomic, so the question is not whether
  they can diverge but what is true when they do. This says the reported answer
  stays consistent: if the copy was not created, nothing claims it was.

  The direction that matters is disk-succeeded-record-failed. A directory with no
  row is inert — nothing looks for it, and a human who finds it can delete it. A
  row with no directory is the opposite: everything downstream believes in it,
  which is why `EpicDispatch` had to learn that a row is not a checkout until it
  reports a root, and why `Agents.start_agent/2` answers
  `{:error, :unknown_working_copy}` rather than starting something against a
  path nobody can resolve.

  So the failure is reported as a failure and the project's list of working
  copies does not grow.

  ## Deliberately not asserted

  Cleanup of the directory. Removing a worktree somebody may have put work in is
  its own risk, and leaving it for a human is defensible — as long as the project
  does not claim it. Criterion 3096 draws the same line.

  ## Red on purpose

  `CreateWorkingCopy` does not exist.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.CreateWorkingCopy
  alias CodeMySpec.WorkingCopies

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The harness does the work on disk and the server does the work on the record" do
    scenario "A half that fails does not leave the other half standing" do
      given_ "the number of working copies this project has", context do
        {:ok, Map.put(context, :before, length(WorkingCopies.list_harnesses(context.scope)))}
      end

      when_ "the call cannot be completed", context do
        # A scope with no project fails the record half after any disk work.
        # Which half fails is not the point; that the answer stays consistent is.
        #
        # No rescue here, deliberately. A first draft wrapped this in try/rescue
        # and the spex passed — the missing module raised, `inspect/1` of the
        # error contained the word "error", and the assertion below matched it.
        # It was green against a tool that does not exist. A tool that cannot be
        # called has to fail this scenario, not satisfy it.
        frame = %Frame{assigns: %{current_scope: %{context.scope | active_project_id: nil}}}

        {:reply, response, _frame} = CreateWorkingCopy.execute(%{label: "doomed"}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the caller is told the copy was not created", context do
        text = response_text(context.response)

        assert text =~ ~r/error|could not|failed|refused|no project/i,
               "the call could not be completed and said nothing about it. Got: #{text}"

        {:ok, context}
      end

      then_ "and nothing is left claiming to be a working copy", context do
        after_count = length(WorkingCopies.list_harnesses(context.scope))

        assert after_count == context.before,
               "a working copy is recorded for a call that failed. A row with no " <>
                 "directory is the dangerous direction: everything downstream " <>
                 "believes in it, where a directory with no row is merely inert."

        {:ok, context}
      end
    end
  end
end
