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
  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.WorkingCopy

  defp reload(%WorkingCopy{id: id}), do: Repo.get!(WorkingCopy, id)

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

    assert main,
           "a project with a checkout and no main copy has no agent, for no reason " <>
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

  test "a project that already has checkouts and no main copy designates none" do
    scope = full_scope_fixture()

    first = checkout(scope, "/workspace/app", "a-laptop")
    _second = checkout(scope, "/workspace/worktree-a", "a-laptop")
    _third = checkout(scope, "/workspace/worktree-b", "a-desktop")

    # What the database holds on a project whose checkouts predate the column —
    # roots everywhere, nothing designated. Written directly because that is
    # history rather than something the app can still produce, which is the
    # whole point of the rule this checks.
    Repo.update_all(WorkingCopy, set: [main: false])

    # A reconnect must change nothing. On this project that reconnect is a
    # worktree nobody is working in, waking on a timer — and it would become the
    # project's main checkout without anybody choosing it.
    {:ok, rejoined} = WorkingCopies.report_root(reload(first), "/workspace/app")

    refute rejoined.main,
           "a reconnect designated a checkout on a project that has several. That is " <>
             "the guess `designate_main/2` exists to rule out — a path, a label and a " <>
             "last-seen time each pick a different wrong one — and it would be made " <>
             "silently, by whichever harness happened to wake up first."

    refute WorkingCopies.main(scope),
           "the project has a main checkout nobody designated"
  end

  test "the main copy keeps the designation when its harness rejoins" do
    scope = full_scope_fixture()
    copy = checkout(scope, "/workspace/app")

    {:ok, rejoined} = WorkingCopies.report_root(copy, "/workspace/app")

    assert rejoined.main,
           "the copy cleared its own designation by reconnecting. `only_checkout?/2` is " <>
             "false once this copy holds the designation, so writing that result back " <>
             "is how a project loses its main checkout on a laptop waking up."

    assert WorkingCopies.main(scope).id == copy.id
  end

  # The case with no coverage, and the one the product hits most: designating
  # the copy that already holds it.
  #
  # `report_root/2` designates the first checkout to report a root, so by the
  # time anybody opens the designation page the copy shown is usually already
  # main — and pressing the button on it cleared the designation while
  # answering `{:ok, copy}`.
  #
  # The clear ran first, by design, because the index permits one `main` row per
  # project. It cleared the target too. The changeset was then built from the
  # struct fetched *before* that clear, which still said `main: true`, so
  # setting `main: true` was no change, `Repo.update/1` issued no statement, and
  # the row was left `false` with a returned struct saying otherwise.
  #
  # The existing test below cannot see it: it designates a *different* copy,
  # where the struct says `false` and the change is real.
  test "designating the copy that already holds it leaves it holding it" do
    scope = full_scope_fixture()
    only = checkout(scope, "/workspace/app", "a-laptop")

    assert WorkingCopies.main(scope).id == only.id,
           "the premise failed: this copy does not already hold the designation, " <>
             "so re-designating it is not what this test exercises"

    {:ok, _} = WorkingCopies.designate_main(scope, only.id)

    assert WorkingCopies.main(scope),
           """
           Designating the copy that already held the designation cleared it.

           The project now has no main working copy, so `running_copy_check/2`
           answers "No running copy designated" for every story and the agent
           that follows the designation goes with it — and the call said `:ok`.
           """

    assert WorkingCopies.main(scope).id == only.id
  end

  test "an explicit designation still moves it" do
    scope = full_scope_fixture()
    _first = checkout(scope, "/workspace/app", "a-laptop")
    second = checkout(scope, "/workspace/other", "a-desktop")

    {:ok, _} = WorkingCopies.designate_main(scope, second.id)

    assert WorkingCopies.main(scope).id == second.id
  end
end
