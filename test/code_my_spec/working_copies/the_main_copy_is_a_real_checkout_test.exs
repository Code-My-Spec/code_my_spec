defmodule CodeMySpec.WorkingCopies.TheMainCopyIsARealCheckoutTest do
  @moduledoc """
  A project's main working copy is somewhere an agent can actually run.

  The designation used to be made at insert: the first *row* on a project became
  its main copy. A row is not a checkout — `issue/3` mints before any root is
  known, and `report_root/2` fills the path in afterwards, if a harness ever
  joins at all. `ensure_default/1`'s nil-object row for writers with no checkout
  never gets one, and neither do test fixtures.

  So a rootless placeholder became the project's main copy, and that is a quiet
  failure of exactly the kind story 963's criterion 2906 is named after: the
  project reports somewhere for its agent to run, `ensure_main_agent/1` starts
  one there with `working_copy: nil`, the machine refuses it, the row stays
  `:starting`, and the page says "Getting ready. It will start work as soon as
  its machine picks it up." — indefinitely, about a directory that does not
  exist. Nothing errors and nothing is actionable.

  The designation is made when a copy first reports a root, which is the moment
  it becomes a checkout.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Devices
  alias CodeMySpec.WorkingCopies

  defp device(scope, hostname) do
    {:ok, device} = Devices.announce(scope, nil, %{hostname: hostname, kind: :local})
    device
  end

  defp checkout(scope, root, hostname \\ "a-laptop") do
    {:ok, copy} =
      WorkingCopies.issue(scope, nil,
        label: root,
        device: device(scope, hostname),
        root: root
      )

    {:ok, copy} = WorkingCopies.report_root(copy, root)
    copy
  end

  test "a row that has never said where it is does not become the main copy" do
    scope = full_scope_fixture()

    # What `user_scope_fixture/3` already minted: a row with no root, standing
    # in for something serving a checkout. It is not one.
    refute WorkingCopies.main(scope),
           "a working copy with no root became the project's main one. An agent " <>
             "started there is started on nowhere, and the page says it is getting " <>
             "ready rather than that there is nothing to get ready on."
  end

  test "the first checkout to report a root becomes the main copy" do
    scope = full_scope_fixture()
    copy = checkout(scope, "/workspace/app")

    main = WorkingCopies.main(scope)

    assert main, "a project with a checkout and no main copy has no agent, for no reason " <>
                   "anybody can act on"

    assert main.id == copy.id
    assert main.root == "/workspace/app"
  end

  test "a second checkout does not take the designation" do
    scope = full_scope_fixture()
    first = checkout(scope, "/workspace/app", "a-laptop")
    _second = checkout(scope, "/workspace/other", "a-desktop")

    assert WorkingCopies.main(scope).id == first.id,
           "a checkout joining took over as the project's main one. Six worktrees of " <>
             "one repository is the ordinary case here, and the last one to start is " <>
             "not the one the work belongs in."
  end

  test "the main copy keeps the designation when its harness rejoins" do
    scope = full_scope_fixture()
    copy = checkout(scope, "/workspace/app")

    {:ok, rejoined} = WorkingCopies.report_root(copy, "/workspace/app")

    assert rejoined.main,
           "the copy cleared its own designation by reconnecting. `first_copy?/1` is " <>
             "false precisely because this copy already holds it, so writing that " <>
             "result back is how a project loses its main copy on a laptop waking up."

    assert WorkingCopies.main(scope).id == copy.id
  end

  test "an explicit designation still moves it" do
    scope = full_scope_fixture()
    _first = checkout(scope, "/workspace/app", "a-laptop")
    second = checkout(scope, "/workspace/other", "a-desktop")

    {:ok, _} = WorkingCopies.designate_main(scope, second.id)

    assert WorkingCopies.main(scope).id == second.id
  end
end
