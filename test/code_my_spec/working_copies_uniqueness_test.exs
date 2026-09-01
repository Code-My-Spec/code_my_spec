defmodule CodeMySpec.WorkingCopiesUniquenessTest do
  @moduledoc """
  One checkout per path per machine per project.

  Issue cb01ce40. The page listed several roots more than once, and the copies
  were byte-for-byte identical — same default label, same path, same "Idle" —
  so there was no means the page offered of telling them apart, not merely none
  at a glance. Three rows for this repo, two each for a couple of worktrees.

  The identity of a checkout is `{project, device, root}`: without the device,
  two boxes at `/workspace/app` are one row, and without the constraint, one box
  at one path is several. There is a unique index for exactly that triple, and
  nothing exercised it — the duplicates in production were cleaned up, which
  leaves no evidence either way about whether they can come back.

  ## The hole Postgres leaves, checked rather than assumed

  A unique index treats NULLs as distinct, so it does not constrain rows with no
  root — the nil-object `ensure_default/1` mints for a writer with no checkout.
  Live, that is one row in the entire database and no project has two, so the
  gap is real and not currently load-bearing. Asserted below so that stops being
  a thing anyone has to go and check by hand.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies.WorkingCopy

  setup do
    scope = full_scope_fixture()
    %{scope: scope, device: device_fixture(scope)}
  end

  defp copy_at(scope, device, root) do
    %WorkingCopy{}
    |> WorkingCopy.changeset(%{
      project_id: scope.active_project_id,
      device_id: device.id,
      root: root,
      label: "the harness at #{root}"
    })
    |> Repo.insert()
  end

  test "a second copy at the same path on the same machine is refused", %{
    scope: scope,
    device: device
  } do
    assert {:ok, _first} = copy_at(scope, device, "/workspace/app")

    assert {:error, changeset} = copy_at(scope, device, "/workspace/app")

    assert "this machine already has a checkout at that path on this project" in errors_on(
             changeset
           ).project_id,
           "a duplicate was accepted, or refused without saying why. The page cannot " <>
             "tell two of these apart — same label, same path, same status — so the " <>
             "refusal is the only thing standing between a list of checkouts and a " <>
             "list with repeats nobody can resolve."
  end

  test "the same path on a different machine is a different checkout", %{
    scope: scope,
    device: device
  } do
    other = device_fixture(scope, %{hostname: "another-box"})

    assert {:ok, _} = copy_at(scope, device, "/workspace/app")

    assert {:ok, _} = copy_at(scope, other, "/workspace/app"),
           "two boxes with a checkout at the same path were treated as one. That is " <>
             "the reason the device is in the key at all — `/workspace/app` is the " <>
             "default path in every container."
  end

  test "a different path on the same machine is a different checkout", %{
    scope: scope,
    device: device
  } do
    assert {:ok, _} = copy_at(scope, device, "/workspace/app")
    assert {:ok, _} = copy_at(scope, device, "/workspace/app/.claude/worktrees/one")
  end

  test "rootless rows are not constrained, which is a known gap", %{
    scope: scope,
    device: device
  } do
    assert {:ok, _} = copy_at(scope, device, nil)

    assert {:ok, _} = copy_at(scope, device, nil),
           "if this starts failing the index has been given NULLS NOT DISTINCT, which " <>
             "is an improvement — update this test rather than the index."
  end
end
