defmodule CodeMySpecSpex.Story1013.Criterion3096Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 3096 — Onboarding that fails leaves nothing behind.

  Rule: Creating a working copy and onboarding it are one act, with no state in
  between that anything else can see.

  The failure path of the same rule, and the harder half. Criterion 3095 says
  nothing sees the in-between while it is working; this says nothing is left
  holding it when it stops.

  The two halves run in different places — the harness makes the checkout on its
  own disk, the server records it — so a failure between them is not a
  hypothetical. It is the ordinary shape of a distributed act: the directory
  exists and the row does not, or the row exists and the directory does not.

  What this asks for is that the *reported* answer is consistent. The project
  does not list a working copy that is not usable, and the caller is told what
  went wrong rather than being left to find a directory nobody can use — which
  is `war-epic` in a different costume: a thing that exists, looks fine, and
  nothing is serving.

  ## Deliberately not asserted

  Whether the directory is deleted. That is a real question and it belongs to
  whoever builds this: removing a worktree somebody might have put work in is
  its own risk, and leaving one behind for a human to find is a defensible
  answer as long as the project does not claim it as a working copy.

  ## Red on purpose

  `CreateWorkingCopy` does not exist.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.CreateWorkingCopy
  alias CodeMySpec.WorkingCopies

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Creating a working copy and onboarding it are one act" do
    scenario "Onboarding that fails leaves nothing behind" do
      given_ "a request that cannot be completed", context do
        # A path the harness cannot make a checkout at is the reachable way to
        # fail the disk half. What matters is that one half fails, not which.
        {:ok, Map.put(context, :root, "/proc/cannot-create-here")}
      end

      when_ "the agent asks for a working copy there", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CreateWorkingCopy.execute(%{label: "doomed", root: context.root}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the project does not list it as a working copy", context do
        roots =
          context.scope
          |> WorkingCopies.list_harnesses()
          |> Enum.map(& &1.root)

        refute context.root in roots,
               "a copy that could not be created is listed as one of the project's. " <>
                 "Everything keyed on the working copy now points at a directory " <>
                 "nobody can use."

        {:ok, context}
      end

      then_ "and I am told what failed", context do
        text = response_text(context.response)

        assert text =~ ~r/error|could not|failed|refused/i,
               "the request could not be completed and the reply does not say so. " <>
                 "Silence here means the agent goes looking for a copy that was " <>
                 "never made. Got: #{text}"

        {:ok, context}
      end
    end
  end
end
