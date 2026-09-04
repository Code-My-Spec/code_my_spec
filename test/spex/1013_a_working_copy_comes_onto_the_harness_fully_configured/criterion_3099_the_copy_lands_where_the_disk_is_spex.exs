defmodule CodeMySpecSpex.Story1013.Criterion3099Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 3099 — The copy lands where the disk is.

  Rule: A working copy is created on a machine that is running a harness, and
  nowhere else.

  The constraint that shapes the whole design. An MCP tool cannot touch a disk it
  is not on, so "create a working copy" is only meaningful where something local
  can run `git worktree add`. John's answer, 2026-09-04: *"make the harness front
  the tool directly and do the client side file work and then pass the call to
  the server to do the server side work."*

  So the machine is not a parameter the caller chooses. It is wherever the
  harness that fronted the call happens to be, which is the only place a
  checkout could have been made.

  ## Why the copy has to name its machine

  Two machines share a path constantly — every container at `/workspace/app` —
  which is why `WorkingCopies.recognise_or_create/3` keys on `device_id` and
  `root` together and never on root alone, and why story 1020's criterion 2843
  established the device as the disambiguator. A created copy is subject to the
  same rule: recording where it is put is what stops it being mistaken for
  somebody else's checkout at the same path.

  ## Red on purpose

  `CreateWorkingCopy` does not exist.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.CreateWorkingCopy
  alias CodeMySpec.WorkingCopies

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A working copy is created on a machine that is running a harness" do
    scenario "The copy lands where the disk is" do
      given_ "a project whose harness runs on one machine", context do
        copy = join_working_copy(context, "/tmp/spex_3099_host", "the machine with the disk")

        {:ok, Map.put(context, :host, copy.working_copy_id)}
      end

      when_ "a working copy is created", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          CreateWorkingCopy.execute(%{label: "on the harness's own disk"}, frame)

        {:ok, Map.put(context, :copies, WorkingCopies.list_harnesses(context.scope))}
      end

      then_ "the copy names the machine it is on", context do
        created = List.last(context.copies)

        assert created && is_binary(created.device_id),
               "a created copy does not say which machine it is on. Two machines " <>
                 "share a path constantly — every container at /workspace/app — so " <>
                 "root alone cannot tell this checkout from somebody else's, which " <>
                 "is why recognition keys on device and root together."

        {:ok, context}
      end
    end
  end
end
