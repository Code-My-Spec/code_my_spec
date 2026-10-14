defmodule CodeMySpec.Agents.ProvisioningFailureTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Provisioning
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.Fixtures

  setup do
    scope = full_scope_fixture()
    Fixtures.install_recording_agent_transport(scope)
    {:ok, _} = WorkingCopies.designate_main(scope, scope.active_working_copy_id)
    main = Fixtures.running_agent(scope, role: "main", continuous: true)
    %{scope: scope, main: main}
  end

  test "a provider refusal reaches the project's agent transport and conversation", ctx do
    other_scope = full_scope_fixture()
    Fixtures.install_recording_agent_transport(other_scope)
    {:ok, _} = WorkingCopies.designate_main(other_scope, other_scope.active_working_copy_id)
    other = Fixtures.running_agent(other_scope, role: "main", continuous: true)
    reason = "Registrar refused to register the domain: token lacks Zone:Edit"

    assert {:halt, %{state: :errored}, ^reason} =
             Provisioning.run_step(ctx.scope, :domain,
               verify: fn _, _ -> {:ok, :absent} end,
               execute: fn _, _, _ -> {:error, reason} end
             )

    main_id = ctx.main.id
    assert_receive {:agent_dispatch, ^main_id, _, _}, 5_000
    messages = Fixtures.messages_to_agent(ctx.scope, main_id)

    assert Enum.any?(messages, fn message ->
             message =~ reason and message =~ "Step: domain" and
               message =~ "Attempted: run the domain step" and
               message =~ ctx.scope.active_project_id
           end)

    assert Fixtures.messages_to_agent(other_scope, other.id) == []
    refute_receive {:agent_dispatch, _, _, _}, 100
  end

  test "a failure waits in the mailbox until the starting agent is present" do
    scope = full_scope_fixture()
    Fixtures.install_recording_agent_transport(scope)
    {:ok, _} = WorkingCopies.designate_main(scope, scope.active_working_copy_id)

    {:ok, main} =
      CodeMySpec.Agents.AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: :main,
        continuous: true,
        status: :starting,
        working_copy: scope.cwd,
        working_copy_id: scope.active_working_copy_id
      })

    assert {:halt, %{state: :errored}, "startup refusal"} =
             Provisioning.run_step(scope, :domain,
               verify: fn _, _ -> {:ok, :absent} end,
               execute: fn _, _, _ -> {:error, "startup refusal"} end
             )

    assert [%{state: :queued}] = CodeMySpec.Agents.Mailbox.entries(scope, main.id)
    refute_receive {:agent_dispatch, _, _, _}, 100

    Fixtures.mark_present(main)

    {:ok, off_main} =
      CodeMySpec.Agents.AgentsRepository.update_agent(scope, main, %{off_at: DateTime.utc_now()})

    assert {:ok, :queued} = CodeMySpec.Agents.Mailbox.pump(scope, main.id)
    refute_receive {:agent_dispatch, _, _, _}, 100
    assert [%{state: :queued}] = CodeMySpec.Agents.Mailbox.entries(scope, main.id)

    {:ok, _} =
      CodeMySpec.Agents.AgentsRepository.update_agent(scope, off_main, %{off_at: nil})

    assert {:ok, _} = CodeMySpec.Agents.Mailbox.pump(scope, main.id)
    main_id = main.id
    assert_receive {:agent_dispatch, ^main_id, _, message}, 5_000
    assert message =~ "startup refusal"
    assert Enum.any?(Fixtures.messages_to_agent(scope, main.id), &(&1 =~ "startup refusal"))
  end

  test "a non-continuous agent is not woken by an automatic repair request", ctx do
    {:ok, _} =
      CodeMySpec.Agents.AgentsRepository.set_agent_continuous(ctx.scope, ctx.main.id, false)

    assert {:halt, %{state: :errored}, "provider refused"} =
             Provisioning.run_step(ctx.scope, :domain,
               verify: fn _, _ -> {:ok, :absent} end,
               execute: fn _, _, _ -> {:error, "provider refused"} end
             )

    refute_receive {:agent_dispatch, _, _, _}, 100
    assert Fixtures.messages_to_agent(ctx.scope, ctx.main.id) == []
  end

  test "missing agent prerequisites leave the provider failure intact" do
    scope = full_scope_fixture()
    Fixtures.install_recording_agent_transport(scope)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:halt, %{state: :errored, provider_error: "provider refused"}, "provider refused"} =
                 Provisioning.run_step(scope, :domain,
                   verify: fn _, _ -> {:ok, :absent} end,
                   execute: fn _, _, _ -> {:error, "provider refused"} end
                 )
      end)

    assert log =~ "could not deliver domain failure"
    refute_receive {:agent_dispatch, _, _, _}, 100
  end

  test "a successful or paused step does not request agent repair", ctx do
    for result <- [{:ok, []}, {:paused, "Register the domain first"}] do
      Provisioning.run_step(ctx.scope, :domain,
        verify: fn _, _ -> {:ok, :absent} end,
        execute: fn _, _, _ -> result end
      )
    end

    assert Fixtures.messages_to_agent(ctx.scope, ctx.main.id) == []
    refute_receive {:agent_dispatch, _, _, _}, 100
  end
end
