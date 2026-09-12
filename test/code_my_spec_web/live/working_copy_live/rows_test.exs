defmodule CodeMySpecWeb.WorkingCopyLive.RowsTest do
  @moduledoc """
  Rows sharing a root are grouped so a reader can tell them apart at a
  glance instead of scanning a list where they are scattered by recency
  (8c9bc2b1).

  `(project, device, root)` is unique at the database level, so the case
  this issue measured — a dozen rows at one root, one device name, one
  label — is a device re-announcing under a fresh id across a harness
  restart, not literally the same device row twice. These fixtures
  reproduce that shape: distinct devices sharing a hostname.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies.WorkingCopy
  alias CodeMySpecWeb.WorkingCopyLive.Rows

  @now ~U[2026-09-12 12:00:00Z]

  setup do
    %{scope: full_scope_fixture()}
  end

  defp insert_copy!(scope, device, root, label, last_seen_at) do
    %WorkingCopy{}
    |> WorkingCopy.changeset(%{
      project_id: scope.active_project_id,
      device_id: device.id,
      root: root,
      label: label,
      last_seen_at: last_seen_at
    })
    |> Repo.insert!()
  end

  describe "list/3" do
    test "rows sharing a root and device name sit together and the newest reports the count", %{
      scope: scope
    } do
      device_before_restart = device_fixture(scope, %{hostname: "Johns-Mac-mini"})
      device_after_restart = device_fixture(scope, %{hostname: "Johns-Mac-mini"})

      older =
        insert_copy!(
          scope,
          device_before_restart,
          "/repo/dup",
          "old copy",
          DateTime.add(@now, -3600, :second)
        )

      newer = insert_copy!(scope, device_after_restart, "/repo/dup", "new copy", @now)

      rows = Rows.list(scope, scope.active_project, @now)
      by_id = Map.new(rows, &{&1.harness.id, &1})

      assert by_id[newer.id].other_copies_at_root == 1,
             "the most recently seen row of a duplicate pair should say how many others share its root"

      assert by_id[older.id].other_copies_at_root == nil,
             "only the representative row of a group reports the count, not every row in it"
    end

    test "a row alone at its root reports nothing", %{scope: scope} do
      device = device_fixture(scope)
      solo = insert_copy!(scope, device, "/repo/solo", "solo copy", @now)

      rows = Rows.list(scope, scope.active_project, @now)
      by_id = Map.new(rows, &{&1.harness.id, &1})

      assert by_id[solo.id].other_copies_at_root == nil
    end

    test "the same root on two differently named machines is not treated as a duplicate", %{
      scope: scope
    } do
      laptop = device_fixture(scope, %{hostname: "a-laptop"})
      sprite = device_fixture(scope, %{hostname: "a-sprite"})

      copy_a = insert_copy!(scope, laptop, "/workspace/app", "on the laptop", @now)
      copy_b = insert_copy!(scope, sprite, "/workspace/app", "on the sprite", @now)

      rows = Rows.list(scope, scope.active_project, @now)
      by_id = Map.new(rows, &{&1.harness.id, &1})

      assert by_id[copy_a.id].other_copies_at_root == nil
      assert by_id[copy_b.id].other_copies_at_root == nil
    end

    test "grouping does not drop or reorder rows outside the duplicate", %{scope: scope} do
      device_before_restart = device_fixture(scope, %{hostname: "Johns-Mac-mini"})
      device_after_restart = device_fixture(scope, %{hostname: "Johns-Mac-mini"})
      elsewhere = device_fixture(scope)

      insert_copy!(
        scope,
        device_before_restart,
        "/repo/dup",
        "old copy",
        DateTime.add(@now, -3600, :second)
      )

      insert_copy!(scope, device_after_restart, "/repo/dup", "new copy", @now)
      other = insert_copy!(scope, elsewhere, "/repo/other", "unrelated copy", @now)

      rows = Rows.list(scope, scope.active_project, @now)
      roots = Enum.map(rows, & &1.harness.root)

      assert Enum.count(roots, &(&1 == "/repo/dup")) == 2
      assert Enum.count(roots, &(&1 == "/repo/other")) == 1
      assert Enum.find(rows, &(&1.harness.id == other.id)).other_copies_at_root == nil
    end
  end
end
