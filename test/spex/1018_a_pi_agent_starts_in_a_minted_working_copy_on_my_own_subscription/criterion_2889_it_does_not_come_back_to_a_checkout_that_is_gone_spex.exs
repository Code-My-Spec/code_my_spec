defmodule CodeMySpecSpex.Story1018.Criterion2889Spex do
  @moduledoc """
  Story 1018 — An agent starts in a minted working copy on my own subscription.
  Criterion 2889 — It does not come back to a checkout that is gone.

  Rule: An agent that went down with its harness comes back with its
  conversation and keeps going.

  The limit on coming back, and story 1014's case reached from the other side.
  A working copy can vanish while its harness is down — a worktree removed, a
  container replaced — and bringing an agent back to a path that is not there is
  worse than leaving it down: it would start, fail on its first tool call, and
  report the failure as something about a file.

  So the refusal is at the start rather than inside the loop, and it names the
  checkout. That is the same clause a fresh start goes through — `Engine.start/1`
  refuses a missing working copy — so this is not a special case for
  restoration, it is restoration going through the ordinary door.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Coming back has a limit" do
    scenario "It does not come back to a checkout that is gone" do
      given_ "an agent that was running on a copy which has since been removed", context do
        copy = CodeMySpec.TempFile.dir("spex_2889")
        File.mkdir_p!(copy)

        agent = Fixtures.running_agent(context.scope, working_copy: copy)
        start_agent(agent.id, working_copy: copy)
        :ok = stop_agent_process(agent.id)

        File.rm_rf!(copy)

        refute File.dir?(copy),
               "the premise is a checkout that is gone; with one still there this " <>
                 "asserts nothing about refusing"

        {:ok, context |> Map.put(:agent, agent) |> Map.put(:copy, copy)}
      end

      when_ "the harness is told to bring it back", context do
        {:ok, Map.put(context, :result, restore_agent(context.agent.id, context.copy))}
      end

      then_ "it refuses, and names the checkout rather than the agent", context do
        assert {:error, :working_copy_missing} = context.result,
               "it tried to bring the agent back to a path that is not there. It " <>
                 "would start, fail on its first tool call, and report that as " <>
                 "something about a file — which is the failure story 1013 was " <>
                 "written to stop. Got: #{inspect(context.result)}"

        {:ok, context}
      end

      then_ "and nothing is left running for it", context do
        refute running?(context.agent.id),
               "a refused restore left something running anyway, which is the " <>
                 "worst of both: the checkout is gone and there is a process " <>
                 "against it"

        {:ok, context}
      end
    end
  end
end
