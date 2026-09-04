defmodule CodeMySpecSpex.Story1013.Criterion3100Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 3100 — One call, two halves.

  Rule: The harness does the work on disk and the server does the work on the
  record, and the caller makes one call.

  The architecture John settled on, 2026-09-04: *"make the harness front the tool
  directly and do the client side file work and then pass the call to the server
  to do the server side work — I think that should work fine."*

  It does, and the mechanism is already there rather than hypothetical.
  `:4004/mcp` is the harness proxy, so a tool can be fronted where the disk is;
  and `HarnessProjectChannel` already runs server→harness request/reply with a
  `ref` for `start_agent`, `fs_request`, `tool_call` and `stop_agent`. What is
  missing is a message scoped to the *machine* rather than to one project root —
  `fs_request` operates on `socket.assigns.project.root`, so it cannot make a
  sibling worktree.

  ## What the caller must not have to know

  That there are two halves at all. An agent asking for somewhere to work should
  not be sequencing a disk operation against a database write, because the
  moment it does, every caller has to get the ordering and the failure handling
  right and they will each get it wrong differently. That is the same argument
  this story already makes about derived values: establish it once, write it
  down, and stop making consumers reconstruct it.

  ## Red on purpose

  `CreateWorkingCopy` does not exist.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.CreateWorkingCopy
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The harness does the work on disk and the server does the work on the record" do
    scenario "One call, two halves" do
      given_ "a connected provider", context do
        {:ok, _integration} = Fixtures.connect_provider(context.scope, :openai)

        {:ok, context}
      end

      when_ "an agent calls the tool that creates a working copy", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CreateWorkingCopy.execute(%{label: "one call"}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the server has recorded the copy and its identity", context do
        copies = WorkingCopies.list_harnesses(context.scope)
        created = List.last(copies)

        assert created,
               "the call returned and the server recorded nothing. The caller made " <>
                 "one call and got half an answer."

        assert is_binary(created.root) and created.root != "",
               "the recorded copy has no root, so the disk half either did not run " <>
                 "or did not report back. A row is not a checkout until it names one."

        {:ok, context}
      end

      then_ "and the agent made one call and waited once", context do
        text = response_text(context.response)

        refute text =~ ~r/now run|next, |then call/i,
               "the reply tells the agent to go and do the other half. An agent " <>
                 "sequencing a disk operation against a database write is every " <>
                 "caller getting the ordering wrong differently. Got: #{text}"

        {:ok, context}
      end
    end
  end
end
