defmodule CodeMySpecSpex.Story1080.Criterion2161Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2161 — An agent's status reads from its open offer.

  Per product: the open offer IS the agent's status -- a read of a stored
  record, not an inferred or computed one (criterion 3275 forbids only the
  latter, e.g. a silence threshold). `list_agent_work` has no such field
  today (`agent_status` there is process lifecycle, `Agents.lifecycle/2`,
  confirmed by reading `WorkRepository.list_agent_work/1`), so this is
  written prescriptive and is expected to fail until the field is added: no
  open offer is idle; an open offer is offered; a declined offer is
  declined; an offer past its last rung is escalated -- each with the
  offer's id and how long it has stood.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers

  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  defp row_for(context, agent_id) do
    {:ok, rows} =
      ListAgentWork.script_result(%{}, %Anubis.Server.Frame{
        assigns: %{current_scope: context.scope}
      })

    Enum.find(rows, &(&1["agent_id"] == agent_id))
  end

  spex "An agent's status reads from its own open offer, not a heuristic", criterion: 2161 do
    scenario "a coder goes from idle, to offered, to declined" do
      given_ "a continuous coder before any work is offered", context do
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        {:ok, Map.put(context, :coder, coder.id)}
      end

      then_ "list_agent_work shows it idle, with no offer id", context do
        row = row_for(context, context.coder)
        assert row["offer_status"] == "idle", inspect(row)
        refute row["offer_id"], inspect(row)
        {:ok, context}
      end

      when_ "coding work is offered to it", context do
        {:ok, offered_work(context)}
      end

      then_ "it shows offered, with the offer's id and how long it has stood", context do
        row = row_for(context, context.coder)
        assert row["offer_status"] == "offered", inspect(row)
        assert row["offer_id"], inspect(row)
        assert row["offer_age_seconds"], inspect(row)
        {:ok, context}
      end

      when_ "it rejects the offer with a reason", context do
        :ok =
          Fixtures.agent_tool_call(context.scope, %{id: context.coder}, "r1", "reject_offer", %{
            "reason" => "already promoted at v2.0.307"
          })

        {:reply, _reply, _} =
          CodeMySpec.McpServers.LocalServer.handle_tool_call(
            "reject_offer",
            %{reason: "already promoted at v2.0.307"},
            agent_frame(context, context.coder)
          )

        {:ok, context}
      end

      then_ "it shows declined, with that offer's id", context do
        row = row_for(context, context.coder)
        assert row["offer_status"] == "declined", inspect(row)
        assert row["offer_id"], inspect(row)
        {:ok, context}
      end
    end

    scenario "a coder ignores its offer through every rung" do
      given_ "a coder offered work, mid-turn", context do
        {:ok, offered_work(context)}
      end

      when_ "it ignores the offer through every rung", context do
        id = context.coder

        Enum.each(1..3, fn _ ->
          :ok = Fixtures.put_agent_mid_turn(context.scope, id)
          :ok = Fixtures.end_turn(context.scope, id)
          assert_receive {:work_turn_requested, ^id, _ref, _rung}, 2_000
        end)

        {:ok, context}
      end

      then_ "list_agent_work shows it escalated, with the offer's id and elapsed time", context do
        row = row_for(context, context.coder)
        assert row["offer_status"] == "escalated", inspect(row)
        assert row["offer_id"], inspect(row)
        assert row["offer_age_seconds"], inspect(row)
        {:ok, context}
      end
    end
  end
end
