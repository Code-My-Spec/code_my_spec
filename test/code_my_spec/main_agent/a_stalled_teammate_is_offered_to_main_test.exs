defmodule CodeMySpec.Agents.Main.AStalledTeammateIsOfferedToMainTest do
  @moduledoc """
  Criterion 1756: a teammate-stalled notice to main is recorded as an offer,
  claimed when main acts on it with any tool call before its turn ends.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Main.AgentWork
  alias CodeMySpec.Agents.Main.Cadence
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.StopDecision
  alias CodeMySpec.Conversations
  alias CodeMySpec.Staffing
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport
  alias CodeMySpecTest.UnreachableMachine
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(Repo, {:shared, self()})
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

    scope = full_scope_fixture()
    {:ok, _main_copy} = Staffing.designate_main(scope, scope.active_working_copy_id)

    %{scope: scope}
  end

  defp main(ctx, attrs \\ %{}) do
    {:ok, main} =
      AgentsRepository.create_agent(
        ctx.scope,
        Map.merge(
          %{
            provider: "anthropic",
            engine: :alloy,
            role: :main,
            status: :running,
            continuous: true,
            working_copy: "/tmp/stalled-#{System.unique_integer([:positive])}",
            working_copy_id: ctx.scope.active_working_copy_id
          },
          attrs
        )
      )

    AgentPresence.present(main)

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        ctx.scope.active_account_id,
        ctx.scope.active_project_id,
        main.id
      )

    on_exit(fn -> :persistent_term.erase({StopDecision, :continuing, main.id}) end)
    Map.put(ctx, :main, main) |> Map.put(:conversation, conversation)
  end

  defp stalled(id) do
    %AgentWork{
      agent_id: id,
      role: :coding,
      working_copy_id: "copy-#{id}",
      agent_status: :running,
      task_status: nil,
      idle?: false,
      turn_started_at: nil,
      tapped_out?: false,
      provider_refusal: nil,
      blocked_reasons: [],
      problems: []
    }
  end

  defp announce(ctx, id) do
    :ok = Cadence.announce_stalls(ctx.scope, [stalled(id)])
    await_dispatches()
  end

  defp await_dispatches do
    CodeMySpec.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref -> assert_receive {:DOWN, ^ref, _, _, _}, 5_000 end)
  end

  defp stalled_offers(ctx) do
    ctx.main.id |> Offers.list_for_agent() |> Enum.filter(&(&1.kind == :stalled))
  end

  defp deliver_notice(ctx) do
    id = ctx.main.id
    assert_received {:agent_dispatch, ^id, ref, _text}

    assert :ok =
             Agents.record_turn_event(ctx.scope, id, %{
               "kind" => "message_delivered",
               "ref" => ref
             })
  end

  defp called(ctx, name) do
    {:ok, _} =
      Conversations.add_tool_call(ctx.conversation, Ecto.UUID.generate(), name, %{}, "main")
  end

  defp end_turn(ctx) do
    {:ok, fresh} = AgentsRepository.fetch_agent(ctx.scope, ctx.main.id)

    {:ok, _} =
      AgentsRepository.update_agent(ctx.scope, fresh, %{
        turn_started_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

    Agents.record_turn_event(ctx.scope, ctx.main.id, %{"kind" => "turn_ended"})
    await_dispatches()
  end

  test "the notice is a :stalled offer on agent:<id>, linked to the notice", ctx do
    ctx = main(ctx)
    announce(ctx, "a1b2c3d4")

    main_id = ctx.main.id
    assert_received {:agent_dispatch, ^main_id, ref, text}
    assert is_binary(ref)

    assert [offer] = stalled_offers(ctx)

    assert %{subject_type: "agent", subject_key: "a1b2c3d4", status: :open} = offer
    assert offer.template_version == "stalled/1"
    assert [%{message_id: message_id}] = offer.messages
    assert Conversations.Message |> Repo.get!(message_id) |> Conversations.Message.text() == text
  end

  test "main's tool call after it claims it at turn end", ctx do
    ctx = main(ctx)
    announce(ctx, "a1b2c3d4")
    deliver_notice(ctx)
    called(ctx, "list_agent_work")
    end_turn(ctx)

    assert [%{status: :claimed}] = stalled_offers(ctx)
  end

  test "no tool call means it is ignored", ctx do
    ctx = main(ctx)
    called(ctx, "list_agent_work")
    announce(ctx, "a1b2c3d4")
    deliver_notice(ctx)
    end_turn(ctx)

    assert [%{status: :ignored}] = stalled_offers(ctx)
  end

  test "a second stall of the same teammate supersedes the first", ctx do
    ctx = main(ctx)
    announce(ctx, "a1b2c3d4")
    announce(ctx, "a1b2c3d4")

    assert [%{status: :superseded}, %{status: :open, attempt: 2}] = stalled_offers(ctx)
  end

  test "a held notice is recorded undelivered", ctx do
    ctx = main(ctx, %{continuous: false})
    announce(ctx, "a1b2c3d4")

    main_id = ctx.main.id
    refute_received {:agent_message, ^main_id, _}
    refute_received {:agent_dispatch, ^main_id, _, _}
    assert [%{status: :undelivered}] = stalled_offers(ctx)
  end

  test "a notice whose send failed is recorded undelivered", ctx do
    Application.put_env(:code_my_spec, :agent_transport, UnreachableMachine)
    ctx = main(ctx)
    announce(ctx, "a1b2c3d4")

    assert [%{status: :undelivered}] = stalled_offers(ctx)
    end_turn(ctx)
    assert [%{status: :undelivered}] = stalled_offers(ctx)
  end
end
