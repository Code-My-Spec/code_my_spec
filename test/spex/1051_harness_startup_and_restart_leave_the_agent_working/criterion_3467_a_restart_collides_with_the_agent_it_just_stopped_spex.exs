defmodule CodeMySpecSpex.Story1051.Criterion3467Spex do
  @moduledoc """
  Story 1051 — Harness startup and restart leave the agent working.
  Criterion 3467 — A restart collides with the agent it just stopped.

  Rule: Stopping an agent leaves nothing behind that breaks the next one.

  3449 is about the collision not happening. This is about what must be true
  when it does — because a collision is a race, and a race that is rare is a
  race that will happen on a busy machine and nowhere else.

  The recorded failure is not the collision. It is what was reported:

      the new process lost, and the row stuck at `:starting` with `os_pid: nil`
      indefinitely while `restart_agent/2` answered `{:ok, agent}`. Nine
      minutes later nothing had retried.

  Success was reported, the agent was down, and because success was reported
  nothing looked again. That is the invariant here — a restart that answers
  success has to leave a running agent — and it is checkable on every restart
  whether or not a collision occurred, which is the point: it is what the
  caller relies on, and it either holds always or it is not something to rely
  on.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers, only: [running?: 1]
  import CodeMySpecSpex.HarnessLifecycleHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.MainAgent.Tools.RestartAgent
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Stopping an agent leaves nothing behind that breaks the next one" do
    scenario "A restart collides with the agent it just stopped" do
      given_ "an agent that is restarted", context do
        context = given_a_staffed_checkout(context, "spex_3467")

        {:ok, Map.put(context, :agent_id, start_agent(context))}
      end

      when_ "the relaunch runs against the stopped agent's own registrations", context do
        {:reply, reply, _frame} =
          RestartAgent.execute(
            %{agent_id: context.agent_id, reason: "it stopped answering"},
            frame(context)
          )

        {:ok,
         context
         |> Map.put(:reply, reply)
         |> Map.put(:text, response_text(reply))
         |> Map.put(:running, running?(context.agent_id))}
      end

      then_ "the caller is never told success while the agent stays down", context do
        assert context.reply.isError or context.running,
               """
               The restart reported success and the agent is not running.

               This is the recorded failure verbatim: the relaunch lost to the
               stopped agent's own registration, the row stuck at `:starting`
               with `os_pid: nil`, and `restart_agent/2` answered `{:ok,
               agent}`. Nine minutes later nothing had retried — because
               nothing had been told there was anything to retry.

               Reporting the failure is the whole remedy. A caller told the
               restart failed looks again; a caller told it worked does not.

               #{context.text}
               """

        {:ok, context}
      end

      then_ "and a failed restart says so in terms the caller can act on", context do
        assert_report_matches_outcome(context.reply.isError, context)

        {:ok, context}
      end
    end
  end

  # A refusal has to name what failed, or the caller has an error and nowhere
  # to go with it.
  defp assert_report_matches_outcome(true, context) do
    assert context.text =~ ~r/(restart|start|agent)/i,
           """
           The restart failed and the reply does not say what failed.

           #{context.text}
           """
  end

  # And a success has to be backed by an agent, which is the whole criterion.
  defp assert_report_matches_outcome(false, context) do
    assert context.running, "success was reported for an agent that is not running"
  end
end
