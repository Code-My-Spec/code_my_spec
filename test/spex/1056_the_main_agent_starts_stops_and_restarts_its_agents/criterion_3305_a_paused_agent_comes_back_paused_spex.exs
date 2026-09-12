defmodule CodeMySpecSpex.Story1056.Criterion3305Spex do
  @moduledoc """
  Story 1056 — The main agent starts, stops and restarts its agents.
  Criterion 3305 — A paused agent comes back paused.

  Rule: a restart restores the state, including the state somebody chose.

  Pausing is a decision. `set_agent_continuous(scope, id, false)` is what a
  person does to an agent that is costing money on work they have not approved,
  or looping, or about to be looked at — and a restart that quietly undoes it
  overrules them without saying so.

  The failure is silent in the direction that costs. A paused agent that comes
  back working does not error, does not warn, and looks exactly like a healthy
  restore; the only symptom is spend, and the only way to notice is to go and
  look at an agent you had deliberately stopped looking at.

  ## What the criterion asks that 3304 does not

  3304 wants the agent back and carrying on. Taken alone, the honest
  implementation of it is "restore everything that was running" — which is
  precisely what breaks this. They are a pair, and this one is the constraint
  the other would otherwise run over.

  Paused means `continuous: false`, which the agent is still *running* with:
  the row is alive, the process is alive, and the thing that is off is being
  woken for new work. The restore answer has to carry that, and today it has
  nowhere to put it — `LaunchRequest.for/1` names the engine, the provider, the
  checkout, the role and the history, and nothing about willingness.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A decision to pause survives the restart" do
    scenario "an agent was paused when the application restarted" do
      given_ "a paused agent and a working one on the same checkout", context do
        reply = join_working_copy(context, "/tmp/spex-3305", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        # The provider these agents run on — `running_agent/2` defaults to zai.
        # `Agents.restart_agent/2`
        # resolves one before it attempts anything — deliberately, so a restart
        # fails here rather than minutes later on the agent's first model call.
        {:ok, _integration} = CodeMySpecSpex.Fixtures.connect_provider(scope, :zai)

        paused =
          Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3305",
            continuous: true
          )

        working =
          Fixtures.running_agent(scope,
            role: "qa",
            working_copy: "/tmp/spex-3305",
            continuous: true
          )

        # Paused the way a person pauses one: switched off, still there.
        {:ok, _agent, :paused} = Fixtures.pause_agent(scope, paused.id)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:paused, paused)
         |> Map.put(:working, working)}
      end

      when_ "the application comes back up and the harness asks what to run",
            context do
        {:ok, Map.put(context, :to_restore, Fixtures.agents_to_restore(context.scope))}
      end

      then_ "it comes back paused", context do
        entry = Enum.find(context.to_restore, &(&1["agent_id"] == context.paused.id))

        assert entry,
               """
               The paused agent is not in the restore answer at all.

               Paused is not stopped. The row is alive and the process is alive;
               what is off is being woken for new work, so dropping it from the
               restore turns a pause into a stop — a different decision, made on
               somebody's behalf.

               to restore:
               #{inspect(context.to_restore)}
               """

        assert entry["continuous"] == false,
               """
               A paused agent comes back willing to be put to work.

               Pausing is a decision somebody made — an agent costing money on
               work they had not approved, or looping, or about to be looked at
               — and a restart that undoes it overrules them without saying so.

               The failure is silent in the direction that costs: no error, no
               warning, indistinguishable from a healthy restore, and the only
               symptom is spend on an agent they had deliberately stopped
               watching.

               entry:
               #{inspect(entry)}
               """

        {:ok, context}
      end

      then_ "and the agent that was not paused is not affected", context do
        entry = Enum.find(context.to_restore, &(&1["agent_id"] == context.working.id))

        assert entry,
               "the working agent was dropped from the restore:\n" <>
                 inspect(context.to_restore)

        refute entry["continuous"] == false,
               """
               An agent nobody paused comes back paused.

               The over-correction, and it fails the same way round: quiet, and
               visible only as work that stops happening.

               entry:
               #{inspect(entry)}
               """

        {:ok, context}
      end
    end
  end
end
