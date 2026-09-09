defmodule CodeMySpecSpex.Story1013.Criterion3095Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 3095 — There is no half-made copy to find.

  Rule: Creating a working copy and onboarding it are one act, with no state in
  between that anything else can see.

  This is the story's original thesis applied to the step it did not used to
  have. The premise has always been that onboarding *establishes* identity,
  databases and proxy "once and writes them down, so that nothing downstream
  derives them" — because every derivation has failed in production, and the
  notes list four of them by name.

  A checkout that exists and has not been onboarded is exactly the thing those
  derivations were reaching for. It is a directory that looks like a working
  copy, has no recorded identity, and will be found by something. The failure
  mode is not that it errors — it is that a consumer derives what is missing and
  gets it wrong, quietly, which is the whole reason this story exists.

  ## What "visible" means here

  Not "on disk". `git worktree add` makes a directory and there is no way to
  make that atomic with a database write. Visible means the project reports it
  as one of its working copies — the answer every consumer asks for.

  ## Red on purpose

  `CreateWorkingCopy` does not exist, so there is no in-between to observe.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.CreateWorkingCopy
  alias CodeMySpec.WorkingCopies

  setup :register_log_in_setup_account
  setup :setup_active_project

  defp created_id(text), do: id_from(Regex.run(~r/^id: (\S+)/m, text))

  defp id_from([_, id]), do: id
  defp id_from(_no_match), do: ""

  spex "Creating a working copy and onboarding it are one act" do
    scenario "There is no half-made copy to find" do
      given_ "a machine holding this project's repository", context do
        copy = join_working_copy(context, "/tmp/spex_3095_host", "the machine with the disk")

        {:ok, Map.put(context, :host, copy.working_copy_id)}
      end

      given_ "an agent has asked for a working copy", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CreateWorkingCopy.execute(%{label: "mid-flight"}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      when_ "I ask the project what working copies it has", context do
        {:ok, Map.put(context, :copies, WorkingCopies.list_harnesses(context.scope))}
      end

      then_ "nothing downstream sees a copy that was not onboarded", context do
        unconfigured =
          Enum.filter(context.copies, fn copy ->
            is_binary(copy.root) and copy.root != "" and is_nil(copy.device_id)
          end)

        assert unconfigured == [],
               "a copy is listed with a root and no machine behind it. That is the " <>
                 "half-state this story exists to prevent: something downstream will " <>
                 "derive what is missing rather than find it recorded."

        {:ok, context}
      end

      then_ "and the one just created is complete", context do
        # The created copy, not every row on the project. A first draft asserted
        # this of all of them and failed on `ensure_default/1`'s rootless
        # nil-object row, which predates the request and is a different problem
        # — one this criterion has no business reporting.
        id = created_id(response_text(context.response))
        created = Enum.find(context.copies, &(&1.id == id))

        assert created, "the copy the reply named is not among the project's copies"

        assert is_binary(created.root) and created.root != "",
               "the created copy has no root. A row is not a checkout until it " <>
                 "reports one, and a rootless row is exactly what `EpicDispatch` " <>
                 "had to grow a guard against."

        assert is_binary(created.device_id),
               "the created copy does not say which machine it is on"

        {:ok, context}
      end
    end
  end
end
