defmodule CodeMySpecSpex.Story1023.Criterion2884Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops costing.
  Criterion 2884 — An agent mid-commit gets to finish it.

  Rule: A stop asks the agent to finish what it is doing before it insists.

  An agent part-way through writing files and committing them has work worth a
  moment. Cutting it off mid-write leaves a half-staged index or a partial file
  in a checkout somebody else will pick up, and the cost of waiting is a few
  seconds of a subscription.

  ## The ask is the signal

  The Three Amigos decision was "tell the lane, then TERM, then KILL", and the
  lane half was dropped after building it. Two things ruled it out: `Agents` may
  not reference `AgentHarness` — a layering violation the boundary correctly
  refuses — and the only consumer would be the `codemyspec` Pi extension, which
  lives in another repository. It would have been a message nothing reads.

  SIGTERM already *is* the ask. It is the standard mechanism, every well-behaved
  process handles it, and the bounded grace period after it is the window in
  which the agent finishes. That is what this asserts, and it is what actually
  guarantees the criterion.

  The marker file stands in for the commit: something that exists only if the
  agent got to complete what it was doing.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StopAgent
  alias CodeMySpec.TempFile
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A stop gives the agent a moment before it insists" do
    scenario "An agent mid-commit gets to finish it" do
      given_ "an agent part-way through writing files and committing them", context do
        dir = TempFile.dir("spex_2884")
        File.mkdir_p!(dir)
        on_exit(fn -> File.rm_rf(dir) end)

        marker = Path.join(dir, "commit-finished")
        process = start_process(finishes_at: marker)
        agent = Fixtures.running_agent(context.scope, process)

        refute File.exists?(marker),
               "the premise is work that has not finished yet"

        {:ok,
         context
         |> Map.put(:agent, agent)
         |> Map.put(:process, process)
         |> Map.put(:marker, marker)}
      end

      when_ "I stop it", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, reply, _frame} = StopAgent.execute(%{"agent_id" => context.agent.id}, frame)
        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it is asked to stop before anything forces it", context do
        assert File.exists?(context.marker),
               "the agent was killed outright rather than asked. Anything it was " <>
                 "part-way through — a commit, a file write — is lost, and what is " <>
                 "left behind sits in a checkout somebody else picks up."

        {:ok, context}
      end

      then_ "and the commit it was making is complete when its process ends", context do
        refute context.reply.isError

        assert in_group(context.process.os_pid) == [],
               "the agent finished its work and is still running, so the stop " <>
                 "never completed"

        {:ok, context}
      end
    end
  end
end
