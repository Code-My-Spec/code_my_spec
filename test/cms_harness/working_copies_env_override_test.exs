defmodule CmsHarness.WorkingCopiesEnvOverrideTest do
  @moduledoc """
  `WorkingCopies.all/0` must answer each root with *its own* id even when
  `CMS_HARNESS_ID` is set in the harness's environment.

  Every worktree session on this machine sets `CMS_HARNESS_ID` for itself
  (`.claude/settings.local.json`'s `env` block), and `just refresh-harness`'s
  own moduledoc says restarting the harness "from any worktree is safe" —
  meaning whatever process launches it inherits that variable. `entry/1` used
  to resolve every root through `HarnessConfig.read/1`, which checks
  `CMS_HARNESS_ID` before it even looks at which root asked, so N roots all
  answered with the same id and a map keyed by id collapsed to one entry —
  measured live as a harness alternating JOIN/CLOSE on three different roots
  roughly once a second, each carrying an id belonging to only one of them.
  """

  # Sync: mutates a node-global OS environment variable. See
  # WorkingCopiesTest's moduledoc for why that has to be sync, not just here.
  use ExUnit.Case, async: false

  import CmsHarnessTest.Projects

  alias CmsHarness.WorkingCopies

  test "each served root answers with its own id, not the env var's" do
    a = project_dir()
    b = project_dir()
    serve(a.root)
    serve(b.root)

    on_exit(fn ->
      stop_project(a.root)
      stop_project(b.root)
    end)

    previous = System.get_env("CMS_HARNESS_ID")
    # Neither project's own id — a real one, the shape a worktree session's
    # own settings.local.json would actually set.
    System.put_env("CMS_HARNESS_ID", Ecto.UUID.generate())

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("CMS_HARNESS_ID")
        value -> System.put_env("CMS_HARNESS_ID", value)
      end
    end)

    known = WorkingCopies.all()

    assert Map.get(known, a.harness_id) == a.root,
           "root a answered with the env var's id instead of its own — " <>
             "got #{inspect(known)}"

    assert Map.get(known, b.harness_id) == b.root,
           "root b answered with the env var's id instead of its own — " <>
             "got #{inspect(known)}"
  end
end
