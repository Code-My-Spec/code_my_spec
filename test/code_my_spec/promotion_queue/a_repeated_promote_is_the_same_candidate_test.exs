defmodule CodeMySpec.PromotionQueue.ARepeatedPromoteIsTheSameCandidateTest do
  @moduledoc """
  Enqueueing is idempotent per copy and commit: a promote repeated after a
  harness restart asks for what is already queued or being gated, and gets
  that entry back rather than a second one (the queue's first live hours,
  2026-10-05: one coder's commit sat in the queue twice).
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.PromotionQueue.Repository
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()
    {:ok, copy} = WorkingCopies.issue(scope, nil, label: "coder", device: device_fixture(scope))
    %{scope: scope, copy: copy}
  end

  defp enqueue(ctx, commit) do
    Repository.enqueue(%{
      project_id: ctx.scope.active_project_id,
      working_copy_id: ctx.copy.id,
      commit: commit,
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
