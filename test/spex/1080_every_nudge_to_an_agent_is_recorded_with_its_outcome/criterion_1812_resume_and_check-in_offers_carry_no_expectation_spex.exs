defmodule CodeMySpecSpex.Story1080.Criterion1812Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1812 — Resume and check-in offers carry no expectation: unlike a
  work offer, which settles "ignored" and escalates when nothing is taken, a
  resume or check-in offer settles at turn end without implying the agent
  should have responded a particular way.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "An open resume offer settles with no expectation when the turn ends", criterion: 1812 do
    scenario "a resumed coder ends its turn without any particular response" do
      given_ "a harness serving a copy with coding work waiting", context do
        {reply, socket} =
          join_working_copy_socket(context, "/tmp/spex-1812-#{System.unique_integer()}", "c1812")

        scope = Fixtures.in_memory_copy(context, reply[:working_copy_id])
        context = Map.merge(context, %{scope: scope, socket: socket})
        context = FullSatisfactionFixtures.apply_up_to_analysis(context)
        Fixtures.fresh_analysis_runs(context.scope, ["compiler", "credo", "exunit"])
        {:ok, put_to_work(context)}
      end

      given_ "a continuous coder holding a task, with no turn in flight, resumed by a restart",
             context do
        coder = Fixtures.running_agent(context.scope, role: "coding")
        context = start_agent_task(context, coder.id, next_task(context, coder.id))
        {:ok, _agent, _disposition} = Fixtures.continue_agent(context.scope, coder.id)

        ref =
          Phoenix.ChannelTest.push(context.socket, "agents_present", %{
            "agent_ids" => [coder.id]
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok)
        assert_receive {:work_turn_requested, _id, _ref, _prompt}, 2_000
        {:ok, Map.put(context, :coder, coder.id)}
      end

      when_ "the agent ends its turn without any particular response to the resume", context do
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.coder)
        :ok = Fixtures.end_turn(context.scope, context.coder)
        {:ok, context}
      end

      then_ "the resume offer settles without being counted as ignored", context do
        assert [offer] = offers(context, context.coder, %{kind: "resume"}), listing(context)
        refute offer.status == "ignored", listing(context)
        {:ok, context}
      end
    end
  end
end
