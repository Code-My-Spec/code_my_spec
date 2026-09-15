defmodule CodeMySpecSpex.Story1051.Criterion3210Spex do
  @moduledoc """
  Story 1051 — Harness startup and restart leave the agent working.
  Criterion 3210 — An idle agent is told the harness restarted.

  Rule: An agent is told when its harness restarts, and told what happened to
  any work of its own that was in flight.

  Inverted from this criterion's earlier form, which asserted the opposite —
  that an idle agent heard nothing. The old premise treated a restart as
  interesting only to an agent with something to lose; this one treats
  startup and restart as two different events for the same reason 3209 does
  for an interrupted agent. Startup hands an agent its system prompt *and*
  its stop-hook menu in one delivery. A restart is a message to an agent that
  already exists, and until now that message went only to the agent with a
  turn open — an idle agent came back knowing nothing had changed, which is
  true, and also came back with no way to find out whether something new had
  arrived while it was gone.

  Two assertions, because they are two different failures. A restart with no
  line is silent — indistinguishable from nothing having happened, which is
  what sent an operator hunting for a stale MCP client for four hours before
  this story existed. A line with no menu tells the agent the world moved and
  gives it nothing to act on, which is a discontinuity of its own kind.

  The menu is checked concretely, against a real live class this scenario
  creates, rather than against a static phrase — an idle agent with a project
  holding no work at all would legitimately be handed an empty menu (that is
  `Menu.render/4`'s own contract: nothing on it would be noise), and asserting
  against that case would prove nothing about whether the mechanism exists.

  Compared on the transcript region rather than the document. The CSRF token
  is regenerated on every render, so two identical pages differ.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers, only: [restart_harness: 1]
  import CodeMySpecSpex.HarnessLifecycleHelpers

  alias CmsHarnessTest.Machine
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent is told when its harness restarts, and told what happened to any work of its own that was in flight" do
    scenario "An idle agent is told the harness restarted" do
      given_ "an agent that is idle with nothing in flight, and live work for its role", context do
        context = given_a_staffed_checkout(context, "spex_3210")

        # A live `:problems` class for the coding role — countable, and not tied
        # to a story, so nothing about story-enforcement scoping can exclude it.
        # Without something live, the menu's own contract says it renders empty,
        # and "it is given its menu" would be untestable rather than false.
        assert {:ok, [_problem]} = Fixtures.record_problem(context.scope, "spex_3210"),
               "the premise is a live problem for this agent's role, and none was recorded"

        agent_id = start_agent(context)

        # Idle is the premise, so it is checked rather than assumed. An agent
        # that happened to be mid-turn here would make this criterion assert
        # 3209's claim and pass for the wrong reason.
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(agent_id),
               "the premise is an idle agent, and this one is working"

        path = Fixtures.agent_conversation_path(context.scope, %{id: agent_id})

        {:ok,
         context
         |> Map.put(:agent_id, agent_id)
         |> Map.put(:path, path)
         |> Map.put(:before, transcript(context, path))}
      end

      when_ "the harness restarts", context do
        restart_harness(context.harness_socket)

        {:ok, Map.put(context, :after, transcript(context, context.path))}
      end

      then_ "a line in its conversation says the harness restarted", context do
        refute context.after == context.before,
               """
               Nothing at all was added to the idle agent's thread.

               Startup and restart are different events: a restart is a
               message to an agent that already exists, and this one never
               arrived.

               before:
               #{context.before}

               after:
               #{context.after}
               """

        assert context.after =~ ~r/restart/i,
               """
               Something was added to the thread but it does not say the
               harness restarted, so the agent has a discontinuity and no name
               for it.

               #{context.after}
               """

        {:ok, context}
      end

      then_ "and it is given its menu, so it can take a turn if there is work", context do
        assert context.after =~ ~r/list_problems/,
               """
               The agent was told its harness restarted and never given its
               menu — the live problem this scenario created never surfaced in
               its thread, so it has no way to learn work exists without
               guessing to call `get_next_requirement` cold.

               A restart is a message to an agent that already exists; the
               menu is what a stop-hook reply already gives it after any other
               turn, and a restart is the one moment that currently skips it
               for an agent with nothing in flight.

               #{context.after}
               """

        {:ok, context}
      end
    end
  end
end
