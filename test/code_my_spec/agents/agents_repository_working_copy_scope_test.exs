defmodule CodeMySpec.Agents.AgentsRepositoryWorkingCopyScopeTest do
  @moduledoc """
  `create_agent/2` is the only writer of an agent row, and `Agents.start_agent/2`
  already refuses a `working_copy_id` this scope does not own before it ever
  gets here — but that invariant belongs on the writer, not on the one caller
  that happens to check today. `foreign_key_constraint(:working_copy_id)` on
  the changeset only proves the id exists *somewhere* in working_copies; it
  says nothing about whose project that row belongs to, so an id that
  genuinely exists — just on another project's checkout — saved cleanly, and
  the agent it started ran in the caller's own tree while every stop decision
  and analyzer alert for it was computed against a different project's copy.
  Issue c0facd8e.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository

  defp attrs(scope, working_copy_id) do
    %{
      engine: :alloy,
      provider: "anthropic",
      role: :coding,
      working_copy: scope.cwd || "/workspace/main",
      working_copy_id: working_copy_id
    }
  end

  test "refuses a working copy id that belongs to another project" do
    mine = full_scope_fixture()
    theirs = full_scope_fixture()

    assert {:error, :cross_project_working_copy} =
             AgentsRepository.create_agent(mine, attrs(mine, theirs.active_working_copy_id))
  end

  test "creates the agent when the working copy is this project's own" do
    mine = full_scope_fixture()

    assert {:ok, agent} =
             AgentsRepository.create_agent(mine, attrs(mine, mine.active_working_copy_id))

    assert agent.working_copy_id == mine.active_working_copy_id
  end

  # Pre-existing, unrelated to this check: the FK constraint on this column is
  # still named `agents_harness_id_fkey`, from before working_copy_id was
  # `harness_id` (`20260824010000_a_working_copy_is_not_a_harness.exs`, which
  # left constraint names as Postgres generated them on purpose). Ecto's
  # `foreign_key_constraint(:working_copy_id)` expects the naming-convention
  # name and never matches, so a genuinely nonexistent id raises rather than
  # returning a changeset error. Asserted here only to pin that
  # `validate_own_working_copy/2` doesn't change that behavior — its
  # `{:error, _} -> :ok` branch for a lookup miss defers to whatever the
  # changeset already does, rather than swallowing it into something new.
  test "an id nothing owns still falls through to the pre-existing behavior, unmodified" do
    mine = full_scope_fixture()

    assert_raise Ecto.ConstraintError, fn ->
      AgentsRepository.create_agent(mine, attrs(mine, Ecto.UUID.generate()))
    end
  end
end
