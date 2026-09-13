defmodule CodeMySpecSpex.Story1051.Criterion3210Spex do
  @moduledoc """
  Story 1051 — Harness startup and restart leave the agent working.
  Criterion 3210 — An idle agent is not told the harness restarted.

  Rule: An agent is told about a restart only when something of its own was in
  flight.

  The other side of 3209, and the one that is easy to get wrong in the generous
  direction. Announcing every restart to every agent is cheap to implement and
  costs the thing the rule exists to protect: an agent woken by news about
  machinery it does not own spends a turn — a real model call, on somebody's
  subscription — establishing that nothing happened to it.

  A harness serves several checkouts and each runs several agents, so "tell
  everyone" is not one message. It is one per agent per restart, and restarts
  come in runs.

  Two assertions, because the message and the wake are separate failures: a
  line added and nothing woken is noise in a transcript, and a wake with no
  line is a turn nobody can account for afterwards.

  Compared on the transcript region rather than the document. The CSRF token is
  regenerated on every render, so two identical pages differ — and this
  criterion's whole claim is that two renders are identical, which against the
  document is false on every run whatever the code does.
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

  spex "An agent is told about a restart only when something of its own was in flight" do
    scenario "An idle agent is not told the harness restarted" do
      given_ "an agent that is idle with nothing in flight", context do
        context = given_a_staffed_checkout(context, "spex_3210")
        agent_id = start_agent(context)

        # Idle is the premise, so it is checked rather than assumed. An agent
        # that happened to be mid-turn here would make this criterion assert
        # 3209's opposite and pass for the wrong reason.
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

      then_ "nothing is added to its conversation", context do
        assert context.after == context.before,
               """
               An agent with nothing in flight was told about the restart
               anyway.

               Nothing of its own was lost, so the line says only that
               machinery it does not own cycled — and a harness serves several
               checkouts running several agents each, so this is one message
               per agent per restart, in runs.

               before:
               #{context.before}

               after:
               #{context.after}
               """

        {:ok, context}
      end

      then_ "and it is not woken", context do
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(context.agent_id),
               """
               The idle agent is working, or has something stacked to work on,
               after a restart that took nothing of its.

               A wake is a model call on somebody's subscription, spent
               establishing that nothing happened.
               """

        {:ok, context}
      end
    end
  end
end
