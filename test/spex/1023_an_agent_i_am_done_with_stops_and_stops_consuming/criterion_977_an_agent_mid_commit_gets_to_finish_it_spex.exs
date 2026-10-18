defmodule CodeMySpecSpex.Story1023.Criterion977Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops consuming.
  Criterion 977 — An agent mid-commit gets to finish it.

  Rule: A stop asks the agent to wind down before it insists, so work already
  in flight — a commit it was making — finishes rather than landing half
  written.

  Drives a real bash tool call against a real git checkout, the way the
  agent's own tool would, rather than a memfs stand-in: a commit is exactly
  the kind of real OS-level side effect `Environments.write_file/3` does not
  reach.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.AgentProcessHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.RealDisk

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A stop lets an in-flight commit land before it insists", criterion: 977 do
    scenario "An agent mid-commit gets to finish it" do
      given_ "an agent part-way through writing files and committing them", context do
        copy = CodeMySpec.TempFile.dir("spex_2884_commit")
        RealDisk.mkdir_p!(copy)
        RealDisk.git_init!(copy)
        RealDisk.write!(Path.join(copy, "work.txt"), "in progress")

        agent = Fixtures.running_agent(context.scope)
        agent_id = start_agent_with_provider(agent.id, working_copy: copy)

        begin_turn(agent_id)

        :ok =
          HeldProvider.release_with_tool_call(
            "bash",
            %{"command" => "git add -A && git commit -q -m 'in progress work'"},
            then: :hold
          )

        # The follow-up request carrying the tool's result only arrives once
        # the real bash call — the commit — has actually finished running.
        :ok = HeldProvider.await_request()

        assert running?(agent_id),
               "the premise is an agent mid-turn, having just run a real commit, with " <>
                 "its process still up; without that this asserts nothing about finishing " <>
                 "work in flight rather than having none"

        {:ok, context |> Map.put(:agent, agent) |> Map.put(:copy, copy)}
      end

      when_ "I stop it", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        reply =
          ToolLibrary.run(
            "turn_off_agent",
            %{"agent_id" => context.agent.id},
            Map.put(frame.assigns, :scope, frame.assigns.current_scope)
          )

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it is asked to stop before anything forces it", context do
        assert match?({:ok, _}, context.reply),
               "stopping an agent that was cooperating reported an error — a graceful " <>
                 "wind-down should succeed, not look like a forced kill. Got: " <>
                 response_text(context.reply)

        {:ok, context}
      end

      then_ "and the commit it was making is complete when its process ends", context do
        refute running?(context.agent.id),
               "the agent is still running after being asked to stop"

        log = RealDisk.git_log_oneline!(context.copy)

        assert log =~ "in progress work",
               "the agent's process ended with the commit it was making never " <>
                 "finished landing, instead of finishing it before the process went. " <>
                 "git log: #{log}"

        {:ok, context}
      end
    end
  end
end
