defmodule CodeMySpec.AgentsDestinationTest do
  @moduledoc """
  An agent starts on the checkout it was asked for.

  Issue e9541b4b. `put_destination/2` filled the working copy *id* in from the
  caller's own scope whenever the caller supplied only a root — which every
  ordinary `start_agent` does, since the MCP tool passes a path and no id. Two
  things followed, and the first hid the second:

  - `names?/2` tests the id before the root, so the main-copy guard matched on
    the caller's own copy and refused starts that named somewhere else. With an
    agent on the main checkout, nothing could be started anywhere, and the
    refusal named a checkout the caller had not mentioned.
  - when the guard did let one through, the row was written against the caller's
    copy. `working_copy_id` is what the working copies page groups by, so an
    agent asked for on one copy appeared on another.

  Story 957's premise is "see every working copy and the agent running on each",
  and two of its criteria need two agents at once — a live Pi one and a quiet
  Claude one, on different copies. Neither was producible.

  The fix defaults the id from the *root* when a root is named. These assert the
  destination rather than the guard, because the guard was right and was being
  handed the wrong answer.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IntegrationsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.WorkingCopy

  setup do
    scope = full_scope_fixture()
    integration_fixture(scope.user, %{provider: :anthropic})

    {:ok, own} = WorkingCopies.fetch(scope.active_working_copy_id)
    device = device_fixture(scope)

    own =
      own
      |> Ecto.Changeset.change(root: "/workspace/main", main: true, device_id: device.id)
      |> Repo.update!()

    other =
      %WorkingCopy{}
      |> WorkingCopy.changeset(%{
        project_id: scope.active_project_id,
        device_id: device.id,
        root: "/workspace/other",
        label: "another checkout"
      })
      |> Repo.insert!()

    # A real caller's scope carries the checkout it is speaking from; the
    # fixture's does not, and `working_copy` is required.
    %{scope: %{scope | cwd: own.root}, own: own, other: other}
  end

  defp start_on(scope, root) do
    Agents.start_agent(scope, %{
      provider: "anthropic",
      role: "coding",
      engine: :pi,
      working_copy: root
    })
  end

  test "naming another checkout puts the agent there", %{scope: scope, other: other} do
    assert {:ok, agent} = start_on(scope, other.root)

    assert agent.working_copy_id == other.id,
           "the agent was asked for on #{other.root} and recorded against the caller's " <>
             "own copy. The working copies page groups by that id, so it would appear " <>
             "on a checkout nobody asked about."
  end

  test "the main copy being busy does not block another checkout", %{
    scope: scope,
    own: own,
    other: other
  } do
    assert {:ok, _} = start_on(scope, own.root)

    assert {:ok, agent} = start_on(scope, other.root),
           "an agent on the main checkout blocked one on a different copy. That is " <>
             "957's premise — every working copy and the agent running on each — and " <>
             "with the main copy occupied, which is its ordinary state, no second " <>
             "agent could be started anywhere."

    assert agent.working_copy_id == other.id
  end

  test "the main copy still holds one agent", %{scope: scope, own: own} do
    assert {:ok, _} = start_on(scope, own.root)

    assert {:error, {:main_copy_occupied, root}} = start_on(scope, own.root),
           "the guard stopped firing. One agent on the main copy is the rule this " <>
             "fix must not have loosened — a second conversation there is " <>
             "indistinguishable from the project's own."

    assert root == own.root
  end

  test "naming nothing still means the caller's own checkout", %{scope: scope, own: own} do
    assert {:ok, agent} =
             Agents.start_agent(scope, %{provider: "anthropic", role: "coding", engine: :pi})

    assert agent.working_copy_id == own.id,
           "a caller who names no checkout must land on their own. Losing that is how " <>
             "the hole this replaced was opened: a start that named nothing was checked " <>
             "against one copy and run on another."
  end
end
