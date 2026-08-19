defmodule CodeMySpec.Files.DroppedComponentLinkTest do
  @moduledoc """
  A `component_id` naming a component that no longer exists must not fail the
  insert.

  `Scanner.resolve_owners/2` reads a fresh read model, so the component was
  there when it was read. Components are project-scoped by design and several
  working copies sync one project at once, so another harness's `ComponentSync`
  can prune one between that read and this insert. The FK then fired inside
  `start_reconcile/2`, killed the task, closed the channel, and the harness
  reconnected and did it again — 23 violations in one window, both working
  copies flapping, nothing repaired because the rollback discarded the manifest
  too. Issue `ef981256`.

  The claim under test is only that the file lands with no owner rather than
  taking the manifest down with it. Re-linking is `ComponentSync`'s job on the
  next sync and is not asserted here.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Files
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  test "a file naming a component that does not exist is stored unowned" do
    scope = full_scope_fixture()
    ghost = Ecto.UUID.generate()

    attrs = %{
      path: "lib/code_my_spec/dropped_link_probe.ex",
      role: :implementation,
      mtime: DateTime.utc_now(),
      size: 42,
      fingerprint: "dropped-link-probe",
      component_id: ghost,
      story_id: nil,
      valid: true,
      validation_errors: nil
    }

    {count, _} = Files.upsert_files(scope, [attrs])

    assert count == 1,
           "the insert failed rather than dropping the dangling link — this is the " <>
             "crash that took down every reconcile for both working copies"

    stored = Enum.find(Files.list_files(scope), &(&1.path == attrs.path))

    assert stored, "the file was not stored at all"

    refute stored.component_id,
           "the file kept a component_id for a component that does not exist, so the " <>
             "FK would fire on any database that enforces it"
  end
end
