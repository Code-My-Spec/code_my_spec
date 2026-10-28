defmodule CodeMySpec.PromotionQueue.ARepeatedPromoteIsTheSameCandidateTest do
  @moduledoc """
  Enqueueing is idempotent per task, copy, and commit: a promote repeated after a
  harness restart asks for what is already queued or being gated, and gets
  that entry back rather than a second one (the queue's first live hours,
  2026-10-05: one coder's commit sat in the queue twice).
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.PromotionQueue
  alias CodeMySpec.PromotionQueue.Repository
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()
    {:ok, copy} = WorkingCopies.issue(scope, nil, label: "coder", device: device_fixture(scope))
    %{scope: scope, copy: copy}
  end

  defp enqueue(ctx, commit), do: enqueue(ctx, commit, nil)

  defp enqueue(ctx, commit, task_id) do
    Repository.enqueue(%{
      project_id: ctx.scope.active_project_id,
      working_copy_id: ctx.copy.id,
      commit: commit,
      task_id: task_id,
      restart: false
    })
  end

  defp open(ctx), do: Repository.queued(ctx.scope.active_project_id, 10)

  test "completion retry reopens the published candidate without losing its receipt", ctx do
    {:ok, entry} = enqueue(ctx, "candidate-a")
    publication = %{"id" => Ecto.UUID.generate(), "head" => "certified", "sequence" => 7}

    {:ok, _} =
      Repository.move(entry, :landed, %{
        result: %{"assignment_held" => true, "publication" => publication}
      })

    assert {:ok, reopened} =
             Repository.reopen_held(%{
               project_id: ctx.scope.active_project_id,
               working_copy_id: ctx.copy.id,
               commit: "candidate-a"
             })

    assert reopened.id == entry.id
    assert reopened.status == :queued
    assert reopened.result["publication"] == publication
  end

  test "a held publication cannot be reopened for a different task", ctx do
    task_id = Ecto.UUID.generate()
    {:ok, entry} = enqueue(ctx, "candidate-a", task_id)
    publication = %{"id" => Ecto.UUID.generate(), "head" => "certified"}

    assert {:ok, _} =
             Repository.move(entry, :landed, %{
               result: %{"assignment_held" => true, "publication" => publication}
             })

    assert :none ==
             Repository.reopen_held(%{
               project_id: ctx.scope.active_project_id,
               working_copy_id: ctx.copy.id,
               commit: "candidate-a",
               task_id: Ecto.UUID.generate()
             })

    assert Repository.get(entry.id).status == :landed
  end

  test "a certified publication survives restart and cannot be retargeted", ctx do
    {:ok, entry} = enqueue(ctx, "candidate-a")
    publication = %{"id" => Ecto.UUID.generate(), "base" => "base", "head" => "certified"}
    {:ok, _} = Repository.move(entry, :gating, %{result: %{"publication" => publication}})
    Repository.requeue_gating(ctx.scope.active_project_id)
    assert Repository.get(entry.id).result["publication"] == publication
    {:ok, replacement} = enqueue(ctx, "candidate-b")
    refute replacement.id == entry.id
    assert Repository.get(entry.id).commit == "candidate-a"
  end

  test "the same commit again while it waits is the same entry", ctx do
    {:ok, first} = enqueue(ctx, "c1")
    assert {:ok, %{id: id}} = enqueue(ctx, "c1")
    assert id == first.id
    assert [%{id: ^id}] = open(ctx)
  end

  test "a reserved candidate can record its gate batch without losing its reservation", ctx do
    {:ok, waiting} = enqueue(ctx, "c1")
    {:ok, reserved} = Repository.move(waiting, :gating, %{result: %{"stage" => "build"}})
    batch_id = Ecto.UUID.generate()

    assert {:ok, %{status: :gating, batch_id: ^batch_id}} =
             Repository.move(reserved, :gating, %{batch_id: batch_id})

    assert {:error, :candidate_no_longer_queued} = Repository.move(waiting, :gating)
  end

  test "the same commit again while it is being gated is the same entry", ctx do
    {:ok, first} = enqueue(ctx, "c1")
    {:ok, _} = Repository.move(first, :gating, %{batch_id: Ecto.UUID.generate()})

    assert {:ok, %{id: id, status: :gating}} = enqueue(ctx, "c1")
    assert id == first.id
    assert open(ctx) == []
  end

  test "a new commit while one waits moves the waiting entry to it", ctx do
    {:ok, first} = enqueue(ctx, "c1")
    assert {:ok, %{id: id, commit: "c2"}} = enqueue(ctx, "c2")
    assert id == first.id
  end

  test "a new commit while one is being gated is queued behind it", ctx do
    {:ok, first} = enqueue(ctx, "c1")
    {:ok, _} = Repository.move(first, :gating, %{batch_id: Ecto.UUID.generate()})

    assert {:ok, %{id: id, status: :queued, commit: "c2"}} = enqueue(ctx, "c2")
    refute id == first.id
  end

  test "a new task withdraws the prior queued task and cannot reserve its stale row", ctx do
    old_task = Ecto.UUID.generate()
    new_task = Ecto.UUID.generate()
    {:ok, old} = enqueue(ctx, "old-revision", old_task)
    assert {:ok, %{id: old_id}} = enqueue(ctx, "old-revision", old_task)
    assert old_id == old.id

    assert {:ok, replacement} = enqueue(ctx, "new-revision", new_task)
    refute replacement.id == old.id
    assert replacement.task_id == new_task
    assert replacement.commit == "new-revision"
    assert Repository.get(old.id).status == :cancelled
    assert Repository.get(old.id).task_id == old_task

    assert {:error, :candidate_no_longer_queued} =
             Repository.move(old, :gating, %{batch_id: Ecto.UUID.generate()})

    assert [%{id: replacement_id}] = open(ctx)
    assert replacement_id == replacement.id
  end

  test "another task cannot reuse a gating candidate at the same revision", ctx do
    old_task = Ecto.UUID.generate()
    new_task = Ecto.UUID.generate()
    {:ok, old} = enqueue(ctx, "shared-revision", old_task)
    assert {:ok, _} = Repository.move(old, :gating, %{batch_id: Ecto.UUID.generate()})

    assert {:ok, replacement} = enqueue(ctx, "shared-revision", new_task)
    refute replacement.id == old.id
    assert replacement.task_id == new_task
    assert Repository.get(old.id).status == :gating

    receipt = PromotionQueue.queued_text({:ok, %{queued: replacement, position: 2}})
    assert receipt =~ replacement.id
    assert receipt =~ replacement.commit
    assert receipt =~ new_task
    assert receipt =~ "Warning: another revision is still queued or gating"
    assert receipt =~ old.id
  end

  # Issue 97b27e62: the worker reads a copy's queued entry once
  # (`Repository.queued/2`), then reserves it later with `move/3`. If a
  # second promote on the same copy retargets that same still-queued row
  # to a new commit in between -- legitimate on its own, per "a new commit
  # while one waits moves the waiting entry to it" above -- the struct the
  # worker is still holding is now stale. Reserving it must not carry that
  # staleness forward: the worker went on to build, gate and land the
  # *old* commit while the row claimed the new one, and the second
  # promote's own requester never heard a true outcome.
  test "reserving a stale read lands on the entry's current commit, not the one it was read at",
       ctx do
    {:ok, stale} = enqueue(ctx, "c1")
    {:ok, retargeted} = enqueue(ctx, "c2")

    assert retargeted.id == stale.id,
           "the premise failed: the second promote did not retarget the first entry"

    assert {:ok, %{id: id, commit: "c2", status: :gating}} =
             Repository.move(stale, :gating, %{batch_id: Ecto.UUID.generate()})

    assert id == stale.id
  end
end
