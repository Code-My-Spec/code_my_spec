defmodule CodeMySpec.Analysis.ValidationHoldsTest do
  use CodeMySpecTest.DataCase, async: false
  import CodeMySpec.UsersFixtures
  alias CodeMySpec.Analysis.{RunsRepository, ValidationHolds}

  setup do
    scope = full_scope_fixture()

    {:ok, working_copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        device: CodeMySpec.DevicesFixtures.device_fixture(scope)
      )

    copy = working_copy.id
    owner = Ecto.UUID.generate()
    next = Ecto.UUID.generate()
    scope = %{scope | active_working_copy_id: copy}

    {:ok, hold} =
      ValidationHolds.create(scope, %{
        owner_agent_id: owner,
        reason: "Serial regression after recovery",
        affected_copy_ids: [copy],
        next_agent_id: next
      })

    %{scope: scope, copy: copy, owner: owner, next: next, hold: hold}
  end

  defp authorize(ctx) do
    ValidationHolds.authorize(ctx.scope, ctx.hold.id, ctx.owner, %{
      authorized_copy_id: ctx.copy,
      source: "exunit",
      args: ["test/corrected_test.exs"],
      next_agent_id: ctx.next
    })
  end

  defp start(ctx) do
    RunsRepository.start_run(ctx.scope, %{
      source: "exunit",
      kind: :partial,
      args: %{"args" => ["test/corrected_test.exs"]}
    })
  end

  test "only the owner can authorize and an authorization admits exactly one matching run", ctx do
    assert {:error, :not_hold_owner} =
             ValidationHolds.authorize(ctx.scope, ctx.hold.id, ctx.next, %{})

    assert {:error, {:validation_held, _, _, _}} = start(ctx)
    assert {:ok, _} = authorize(ctx)

    assert {:error, {:validation_held, _, _, _}} =
             RunsRepository.start_run(
               ctx.scope,
               %{source: "exunit", kind: :partial, args: %{"args" => ["test/other_test.exs"]}}
             )

    assert {:ok, run} = start(ctx)
    assert {:error, {:validation_held, _, _, _}} = start(ctx)
    assert [hold] = ValidationHolds.list(ctx.scope)
    assert hold.status == :running
    assert hold.run_id == run.id
  end

  test "terminal failure releases execution but requires a recorded handoff and never passes validation",
       ctx do
    {:ok, _} = authorize(ctx)
    {:ok, run} = start(ctx)
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "validation_holds:#{ctx.scope.active_project_id}")

    assert {:ok, _} =
             RunsRepository.finish_run(run, :completed, %{
               exit_status: 2,
               output: "1 test, 1 failure"
             })

    assert_receive {:validation_hold, hold}
    assert hold.status == :awaiting_handoff
    assert hold.outcome["validation_passed"] == false
    assert hold.next_agent_id == ctx.next
    message = CodeMySpec.Agents.ValidationHoldReport.message(hold)
    assert message =~ ctx.owner
    assert message =~ ctx.next
    assert message =~ "Execution ownership is released"
    assert message =~ "Failure is not a validation pass"
    assert {:error, {:validation_held, _, _, _}} = start(ctx)
    assert {:ok, _} = authorize(ctx)
    assert [handed] = ValidationHolds.list(ctx.scope)
    assert Enum.any?(handed.history["events"], &(&1["outcome"] == hold.outcome))
  end

  test "success also requires explicit handoff and does not automatically start another run",
       ctx do
    {:ok, _} = authorize(ctx)
    {:ok, run} = start(ctx)
    {:ok, _} = RunsRepository.finish_run(run, :completed, %{exit_status: 0})
    assert [hold] = ValidationHolds.list(ctx.scope)
    assert hold.status == :awaiting_handoff
    assert hold.outcome["validation_passed"]
    assert {:error, {:validation_held, _, _, _}} = start(ctx)
    assert {:ok, _} = ValidationHolds.release(ctx.scope, hold.id, ctx.owner)
    assert ValidationHolds.promotion_allowed?(ctx.scope.active_project_id)
  end

  test "unknown execution cannot be released or retried without terminal evidence", ctx do
    {:ok, _} = authorize(ctx)
    {:ok, run} = start(ctx)
    {:ok, _} = RunsRepository.finish_run(run, :failed, %{stats: %{"orphaned" => true}})
    assert [hold] = ValidationHolds.list(ctx.scope)
    assert hold.status == :unknown

    assert {:error, :execution_not_released} =
             ValidationHolds.release(ctx.scope, hold.id, ctx.owner)

    assert {:error, :execution_not_released} = authorize(ctx)

    assert {:ok, confirmed} =
             ValidationHolds.confirm_termination(
               ctx.scope,
               hold.id,
               ctx.owner,
               "Operator verified process identity and confirmed termination"
             )

    assert confirmed.status == :awaiting_handoff
    refute confirmed.outcome["validation_passed"]
    assert {:ok, _} = ValidationHolds.release(ctx.scope, hold.id, ctx.owner)
  end

  test "promotion cannot take the slot until the hold is released, and an active gate prevents a new hold",
       ctx do
    alias CodeMySpec.PromotionQueue.Repository

    {:ok, entry} =
      Repository.enqueue(%{
        project_id: ctx.scope.active_project_id,
        working_copy_id: ctx.copy,
        commit: String.duplicate("a", 40),
        restart: false
      })

    assert {:error, :validation_held} = Repository.move(entry, :gating)
    assert Repository.get(entry.id).status == :queued
    assert {:ok, _} = ValidationHolds.release(ctx.scope, ctx.hold.id, ctx.owner)
    assert {:ok, _} = Repository.move(entry, :gating)

    assert {:error, :execution_or_promotion_active} =
             ValidationHolds.create(
               ctx.scope,
               %{
                 owner_agent_id: ctx.owner,
                 reason: "Another regression",
                 affected_copy_ids: [ctx.copy],
                 next_agent_id: ctx.next
               }
             )
  end

  test "confirmed cancellation releases execution without certifying validation", ctx do
    {:ok, _} = authorize(ctx)
    {:ok, run} = start(ctx)

    {:ok, _} =
      RunsRepository.finish_run(run, :failed, %{
        stats: %{"execution_terminal" => true, "cancelled" => true}
      })

    assert [hold] = ValidationHolds.list(ctx.scope)
    assert hold.status == :awaiting_handoff
    assert hold.outcome["execution_known"]
    refute hold.outcome["validation_passed"]
    assert {:ok, _} = ValidationHolds.release(ctx.scope, hold.id, ctx.owner)
  end

  test "an existing tracked run can acquire durable ownership without starting another execution",
       ctx do
    {:ok, _} = ValidationHolds.release(ctx.scope, ctx.hold.id, ctx.owner)
    {:ok, run} = start(ctx)

    {:ok, adopted} =
      ValidationHolds.create(ctx.scope, %{
        owner_agent_id: ctx.owner,
        reason: "Take ownership of existing execution",
        affected_copy_ids: [ctx.copy],
        next_agent_id: ctx.next,
        run_id: run.id
      })

    assert adopted.status == :running
    assert adopted.run_id == run.id
    assert {:error, {:validation_held, _, _, _}} = start(ctx)
    {:ok, _} = RunsRepository.finish_run(run, :completed, %{exit_status: 2})

    assert Enum.find(ValidationHolds.list(ctx.scope), &(&1.id == adopted.id)).status ==
             :awaiting_handoff
  end

  test "scope cannot mutate another project's hold", ctx do
    other = full_scope_fixture()
    assert {:error, :not_hold_owner} = ValidationHolds.release(other, ctx.hold.id, ctx.owner)
    assert ValidationHolds.list(other) == []
  end
end
