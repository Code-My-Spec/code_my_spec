defmodule CodeMySpec.Requirements.AnOrphanIsAComponentThisTreeHasTest do
  @moduledoc """
  A component whose only file lives in somebody else's worktree is not this
  project's orphan.

  The orphan gate asks two things of a component: is it covered by a story, and
  is it *present*. Presence is the per-checkout half — `files` carries
  `component_id` and `working_copy_id` on the same row — and a reader that names
  no checkout is answered from the project's main one, like every other file
  read. `Files.component_ids_present/1` blended every checkout instead.

  The two halves of the graph disagreed about it for as long as both existed:
  `Requirements.Profiles` reads main, `Files.component_ids_present/1` read
  everything, and `ArchitectureChecker` is handed one or the other depending on
  which computed the verdict.

  ## Measured

  On dev, 2026-09-17: `CodeMySpecWeb.WorkingCopiesLive` had one file in the
  whole project — a spec in one worktree, in no other tree including main.
  Blended, it read as present, uncovered, and so an orphan the project had to
  resolve, reported to every agent at every checkout, none of which has the
  file. The docstring on `component_ids_present/1` already described this
  failure with the checkouts the other way round.

  ## Why this is asserted on the checker rather than on the verdict

  `architecture_designed` has three gates in order and the proposal file is the
  first, so a scenario that gets the presence rule wrong and the proposal wrong
  too passes for the wrong reason. `orphans/1` is the gate itself.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ComponentsFixtures
  alias CodeMySpec.Requirements.ArchitectureChecker
  alias CodeMySpec.Users.Scope
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  describe "a context with no story and no file in this tree" do
    test "is not reported as an orphan to a reader that named no checkout",
         %{scope: %Scope{} = project_scope} do
      other = Fixtures.live_agent_scope(project_scope, label: "somebody else's worktree")
      {:ok, _} = CodeMySpec.WorkingCopies.designate_main(project_scope, main_copy_id(other))

      orphan = ComponentsFixtures.component_fixture(project_scope, %{type: "context"})

      # The component's only file, and it is in a checkout that is not main.
      place_file(other, orphan)

      unscoped = %{project_scope | active_working_copy_id: nil}

      refute orphan.id in Enum.map(ArchitectureChecker.orphans(unscoped), & &1.id),
             """
             A component whose only file is in another worktree was reported as
             this project's orphan.

             Presence is a per-checkout fact, and a reader with no checkout is
             answered from main like every other file read. Blended, one stale
             worktree keeps a component alive and every agent at every other
             checkout is told to resolve it — with resolutions that all act on a
             file they do not have.
             """
    end

    test "is reported as an orphan to the checkout that has it",
         %{scope: %Scope{} = project_scope} do
      other = Fixtures.live_agent_scope(project_scope, label: "somebody else's worktree")
      {:ok, _} = CodeMySpec.WorkingCopies.designate_main(project_scope, main_copy_id(other))

      orphan = ComponentsFixtures.component_fixture(project_scope, %{type: "context"})

      place_file(other, orphan)

      # Without this the criterion above passes for a rule that reports nothing
      # as an orphan anywhere, which is the same gate switched off.
      assert orphan.id in Enum.map(ArchitectureChecker.orphans(other), & &1.id),
             """
             The checkout that actually has the file was not told about its own
             orphan. Narrowing presence to a checkout has to keep answering that
             checkout's question.
             """
    end
  end

  # This component's only file, in the checkout the scope names.
  defp place_file(%Scope{} = scope, component) do
    {_n, _} =
      CodeMySpec.Files.upsert_files(scope, [
        %{
          path: "lib/" <> Macro.underscore(component.module_name) <> ".ex",
          role: :implementation,
          component_id: component.id,
          valid: true,
          mtime: DateTime.utc_now()
        }
      ])

    :ok
  end

  # A checkout of this project that is not the one holding the orphan's file, so
  # "main" is a tree the file is not in.
  defp main_copy_id(%Scope{} = other) do
    CodeMySpec.WorkingCopies.list_harnesses(other)
    |> Enum.reject(&(&1.id == other.active_working_copy_id))
    |> case do
      [copy | _] -> copy.id
      [] -> flunk("the project has only one checkout, so nothing can be elsewhere")
    end
  end
end
