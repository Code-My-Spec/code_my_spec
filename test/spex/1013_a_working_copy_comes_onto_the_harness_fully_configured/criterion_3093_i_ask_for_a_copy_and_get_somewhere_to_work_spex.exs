defmodule CodeMySpecSpex.Story1013.Criterion3093Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 3093 — I ask for a copy and get somewhere to work.

  Rule: An agent asks for a working copy and gets one it can work in.

  The scope this story explicitly did not have. Question `2ec33878` asked
  whether `mix harness.onboard` creates the worktree itself or runs inside one
  that already exists, and it was resolved the second way — onboarding
  configures the copy it is run in, and making the copy was somebody else's
  problem.

  Nobody else had it. Story 956's title says "a minted working copy" and not one
  of its thirteen criteria mints anything; 964 hands an epic to a copy and
  assumes one exists. So a project's first epic had nowhere to go but the main
  checkout — where a roster is refused, correctly, because the main copy holds
  one agent and it is the project's own.

  John, 2026-09-04, reopening it: *"what I had intended is that there would be
  an MCP tool for creating and staffing one of these working copies and then it
  would handle all of this stuff ... the agent needs to be able to say give me a
  working copy, and we got a worktree, onboard it, and then the agents are up
  and running inside that worktree."*

  ## Red on purpose

  `CreateWorkingCopy` does not exist. The tool namespace is the one
  `ListWorkingCopies` already uses, so this names where it goes as well as what
  it does.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.CreateWorkingCopy

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent asks for a working copy and gets one it can work in" do
    scenario "I ask for a copy and get somewhere to work" do
      given_ "a project whose main checkout is on a machine running a harness",
             context do
        copy = join_working_copy(context, "/tmp/spex_3093_main", "the project's checkout")

        {:ok, Map.put(context, :main, copy.working_copy_id)}
      end

      when_ "an agent asks for a working copy", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CreateWorkingCopy.execute(%{label: "the war epic's copy"}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "a checkout exists on that machine", context do
        text = response_text(context.response)

        assert text =~ ~r/\/.+/,
               "the reply names no path, so the agent has been told a copy was made " <>
                 "and not where. Got: #{text}"

        {:ok, context}
      end

      then_ "and the agent is told where it is and can start work in it", context do
        text = response_text(context.response)

        refute text =~ ~r/error|could not|failed/i,
               "asking for a working copy on a project that has a harness is the " <>
                 "ordinary case, and it failed: #{text}"

        {:ok, context}
      end
    end
  end
end
