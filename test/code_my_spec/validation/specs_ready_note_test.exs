defmodule CodeMySpec.Validation.SpecsReadyNoteTest do
  @moduledoc """
  `51e319db` — specs_ready is a project-wide latch, stamped with when and on
  what commit it was earned so a checkout without that commit can tell it
  inherited the latch. Clearing the latch clears its stamp.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.{StoriesFixtures, UsersFixtures}

  alias CodeMySpec.Configurations
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.Stories

  setup do
    tmp = CodeMySpec.TempFile.owned_dir("specs_ready_note")
    environment = ExecutionContext.new(:local, tmp)
    scope = put_fixture_execution_context(%{full_scope_fixture() | cwd: tmp}, environment)
    :ok = register_working_copy_execution_context(scope, environment)

    Configurations.get_or_create(scope)
    # spex defaults to :off for a fresh project (nothing has ever gone green
    # yet to protect) — this test is specifically about a spex finding
    # blocking, so it needs the mode a project earns once it has stories
    # worth holding the line on.

    %{scope: scope, tmp: tmp}
  end

  test "clearing specs_ready wipes the stamp", %{scope: scope} do
    story = story_fixture(scope, %{title: "Reverted"})

    {:ok, story} =
      Stories.set_specs_ready(scope, story, true, at: DateTime.utc_now(), commit: "deadbeef")

    {:ok, cleared} = Stories.set_specs_ready(scope, story, false)

    assert cleared.specs_ready == false
    assert cleared.specs_ready_at == nil
    assert cleared.specs_ready_commit == nil
  end
end
