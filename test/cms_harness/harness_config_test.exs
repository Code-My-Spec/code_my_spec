defmodule CmsHarness.HarnessConfigTest do
  @moduledoc """
  A working copy says which harness it is, in one file.

  There are two formats: `.cms_harness.json`, and the id-only
  `.cms_harness_id` it replaced. `read/1` has always preferred the JSON, so
  behaviour was never ambiguous — but `write/2` left the old file in place, so a
  migrated working copy carried both, naming different ids, with nothing on disk
  saying which counted. devops-qa held `5d5c599b` in one and `8a663385` in the
  other; the first person to look concluded they disagreed.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.HarnessConfig

  @legacy_id "5d5c599b-4be7-4e41-8c94-3ab878cab753"
  @current_id "8a663385-d043-4538-bcb3-4b4a31a8c207"

  setup do
    {:ok, root} = Briefly.create(directory: true)
    %{root: root}
  end

  defp legacy_path(root), do: Path.join(root, ".cms_harness_id")

  describe "read/1" do
    test "prefers the current file when both exist", %{root: root} do
      File.write!(legacy_path(root), @legacy_id <> "\n")
      :ok = HarnessConfig.write(root, %{harness_id: @current_id, project_id: "p1"})

      assert {:ok, %{harness_id: @current_id}} = HarnessConfig.read(root)
    end

    test "falls back to the legacy file, and reports no project id", %{root: root} do
      File.write!(legacy_path(root), @legacy_id <> "\n")

      assert {:ok, %{harness_id: @legacy_id, project_id: nil, root: ^root}} =
               HarnessConfig.read(root)
    end

    test "an empty legacy file is not an identity", %{root: root} do
      File.write!(legacy_path(root), "\n")

      assert :none = HarnessConfig.read(root)
    end

    test "no file at all is not an error", %{root: root} do
      assert :none = HarnessConfig.read(root)
    end
  end

  describe "write/1 completes the migration" do
    # The actual fix. Writing the current file is the moment the old one stops
    # being anything but a trap.
    test "the legacy file is removed", %{root: root} do
      File.write!(legacy_path(root), @legacy_id <> "\n")

      :ok = HarnessConfig.write(root, %{harness_id: @current_id, project_id: "p1"})

      refute File.exists?(legacy_path(root)),
             "leaving it is how one working copy ends up naming two harnesses"

      assert {:ok, %{harness_id: @current_id, project_id: "p1"}} = HarnessConfig.read(root)
    end

    test "no legacy file is not a failure", %{root: root} do
      assert :ok = HarnessConfig.write(root, %{harness_id: @current_id, project_id: "p1"})
      assert {:ok, %{harness_id: @current_id}} = HarnessConfig.read(root)
    end

    test "the root is recorded, so nothing has to discover it", %{root: root} do
      :ok = HarnessConfig.write(root, %{harness_id: @current_id, project_id: "p1"})

      assert {:ok, %{root: written}} = HarnessConfig.read(root)
      assert Path.expand(written) == Path.expand(root)
    end
  end
end
