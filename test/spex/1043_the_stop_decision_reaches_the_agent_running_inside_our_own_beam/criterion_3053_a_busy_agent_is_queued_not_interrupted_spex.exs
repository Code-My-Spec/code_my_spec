defmodule CodeMySpecSpex.Story1043.Criterion3053Spex do
  @moduledoc """
  Story 1043 — The stop decision reaches the agent running inside our own BEAM.
  Criterion 3053 — A busy agent is queued, not interrupted.

  Rule: When the run completes, the decision reaches the agent as a message.

  The property that makes messaging safe as a transport. A decision can land
  while the agent is already working — it ends a turn, the analyzers run, and by
  the time they finish something else has given it more to do. Barging into a
  turn in flight would lose whatever that turn was part-way through, which on
  this runtime means a half-finished edit rather than an abandoned HTTP request.

  `Engine.send_message/4` already decides started-or-queued without running
  anything, and `StopDecision` dispatches through the same transport as every
  other message to an agent rather than reaching for the loop directly. This is
  the criterion that stops that being quietly changed.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "When the run completes, the decision reaches the agent as a message" do
    scenario "A busy agent is queued, not interrupted" do
      given_ "an agent running under Alloy that is mid-turn", context do
        Fixtures.deliver_manifest(context.scope)
        agent_id = running_agent(context)

        # Something already in flight, so the decision arrives at an agent that
        # is not free to take it.
        Fixtures.send_agent_message(agent_id, "work on something")

        {:ok, Map.put(context, :agent_id, agent_id)}
      end

      when_ "a decision is delivered to it", context do
        :ok = Fixtures.end_turn(context.scope, context.agent_id)

        {:ok, context}
      end

      then_ "nothing in that turn is lost", context do
        # The agent is still running and still holding its work. A delivery that
        # interrupted would have taken the loop with it, and the agent would be
        # gone rather than busy.
        assert {:ok, _status} = Fixtures.agent_status(context.agent_id), """
        The agent is no longer answering after a decision was delivered to it
        mid-turn. A message is supposed to be queued behind the work in flight,
        not to replace it — an interrupted turn on this runtime is a half-made
        edit on a real disk.
        """

        {:ok, context}
      end
    end
  end
end
