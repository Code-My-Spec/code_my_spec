defmodule CodeMySpec.Agents.MainHearsWhenATeammateStallsOrDiesTest do
  @moduledoc """
  a31f1cd6 step 4b: main is told when a teammate dies, is reaped, or stalls —
  once, on the transition — and is woken for it past its own open question
  (John).
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Main.AgentWork
  alias CodeMySpec.Agents.Main.Cadence
  alias CodeMySpec.Agents.Main.Digest
  alias CodeMySpec.Notifications
  alias CodeMySpec.Staffing
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

    scope = full_scope_fixture()
    {:ok, _main_copy} = Staffing.designate_main(scope, scope.active_working_copy_id)

    {:ok, feature} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a feature checkout",
        device: device_fixture(scope)
      )

    %{scope: scope, feature: feature}
  end

  defp agent(scope, role, copy_id, attrs) do
    {:ok, agent} =
      AgentsRepository.create_agent(
        scope,
        Map.merge(
          %{
            provider: "anthropic",
            engine: :alloy,
            role: role,
            status: :running,
            continuous: true,
            working_copy: "/tmp/teammate-#{System.unique_integer([:positive])}",
            working_copy_id: copy_id
          },
          attrs
        )
      )

    agent
  end

  defp main(ctx, attrs \\ %{}),
    do: agent(ctx.scope, :main, ctx.scope.active_working_copy_id, attrs)

  defp coder(ctx, attrs \\ %{}), do: agent(ctx.scope, :coding, ctx.feature.id, attrs)

  defp told(%{id: id}) do
    assert_receive {:agent_dispatch, ^id, ref, text}, 2_000
    assert is_binary(ref)
    text
  end

  describe "a teammate dying" do
    test "main is told who died, its role and copy, and why", ctx do
      main = main(ctx)
      coder = coder(ctx)

      Agents.record_turn_event(
        ctx.scope,
        coder.id,
        %{"kind" => "agent_died", "text" => "exit: :killed"},
        []
      )

      text = told(main)
      assert text =~ coder.id
      assert text =~ "coding"
      assert text =~ ctx.feature.id
      assert text =~ "exit: :killed"
    end

    test "a reaped teammate is told the same way", ctx do
      main = main(ctx)
      coder = coder(ctx)

      :ok = Agents.record_running_on_copy(ctx.scope, ctx.feature.id, [])

      text = told(main)
      assert text =~ coder.id
      assert text =~ "no longer reports them running"
    end

    test "three reaped in one sweep reach main as one message naming all three", ctx do
      main = main(ctx)
      reaped = [coder(ctx), agent(ctx.scope, :qa, ctx.feature.id, %{}), coder(ctx)]

      :ok = Agents.record_running_on_copy(ctx.scope, ctx.feature.id, [])

      text = told(main)
      for %{id: id} <- reaped, do: assert(text =~ id)
      main_id = main.id
      refute_receive {:agent_dispatch, ^main_id, _, _}, 300
    end

    test "a harness report that reaps three sends one message too", ctx do
      main = main(ctx)
      reaped = [coder(ctx), agent(ctx.scope, :qa, ctx.feature.id, %{}), coder(ctx)]

      {:ok, _running} =
        Agents.record_reported(ctx.scope, [
          %{"agent_id" => main.id, "role" => "main", "working_copy_id" => main.working_copy_id}
        ])

      text = told(main)
      for %{id: id} <- reaped, do: assert(text =~ id)
      main_id = main.id
      refute_receive {:agent_dispatch, ^main_id, _, _}, 300
    end

    test "a sweep that reaped main too sends nothing", ctx do
      main = main(ctx)
      _coder = coder(ctx)

      {:ok, _running} = Agents.record_reported(ctx.scope, [])

      main_id = main.id
      refute_receive {:agent_dispatch, ^main_id, _, _}, 300
    end

    test "reaches main past its own open question to the user", ctx do
      main = main(ctx)
      coder = coder(ctx)

      {:ok, _} =
        Notifications.create_agent_question_request(
          ctx.scope,
          main.id,
          %{
            "title" => "Which way",
            "holder" => "user",
            "questions" => [%{"question" => "Which way?", "options" => []}]
          },
          nil
        )

      Agents.record_turn_event(ctx.scope, coder.id, %{"kind" => "agent_died", "text" => "x"}, [])

      assert told(main) =~ coder.id
    end

    test "a non-continuous main is not woken by it", ctx do
      main = main(ctx, %{continuous: false})
      coder = coder(ctx)

      Agents.record_turn_event(ctx.scope, coder.id, %{"kind" => "agent_died", "text" => "x"}, [])

      main_id = main.id
      refute_receive {:agent_dispatch, ^main_id, _, _}, 300
    end
  end

  describe "a teammate stalling" do
    defp stalled(id, role \\ :coding) do
      %AgentWork{
        agent_id: id,
        role: role,
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

    defp working(id), do: %{stalled(id) | task_status: :active}

    test "is announced on the transition into stalled, once" do
      digest = %Digest{work: [stalled("a"), working("b")]}

      assert {["a"], seen} = ids(Cadence.stall_transitions(MapSet.new(), digest))
      assert {[], ^seen} = ids(Cadence.stall_transitions(seen, digest))

      # Recovering and stalling again is a new transition.
      {_, recovered} = Cadence.stall_transitions(seen, %Digest{work: [working("a")]})
      assert {["a"], _} = ids(Cadence.stall_transitions(recovered, digest))
    end

    test "main itself is never reported as a stalled teammate" do
      digest = %Digest{work: [stalled("m", :main)]}
      assert {[], _} = ids(Cadence.stall_transitions(MapSet.new(), digest))
    end

    test "a digest that could not be built changes nothing" do
      seen = MapSet.new(["a"])
      assert {[], ^seen} = Cadence.stall_transitions(seen, Digest.failed("down"))
    end

    test "main is told who stalled", ctx do
      main = main(ctx)

      :ok = Cadence.announce_stalls(ctx.scope, [stalled("a1b2c3d4")])

      text = told(main)
      assert text =~ "a1b2c3d4"
      assert text =~ "coding"
      assert text =~ "STALLED"
    end

    defp ids({entries, seen}), do: {Enum.map(entries, & &1.agent_id), seen}
  end
end
