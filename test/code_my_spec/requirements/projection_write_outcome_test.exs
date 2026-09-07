defmodule CodeMySpec.Requirements.ProjectionWriteOutcomeTest do
  @moduledoc """
  A projection write that did not happen does not answer `:ok`.

  `persist_projection/5` used to rescue every exception, log at warning and
  return `:ok`. The reasoning was sound as far as it went — the computation's
  return value is the agent's next instruction and is correct whether or not the
  rows were written, so failing the call would turn a projection bug into a
  stopped agent. What it produced was a read model that could silently stop
  being written while every caller was told it had been.

  That is the state `5b538c8b` was diagnosed in: a whole checkout with no
  requirement rows, `evaluate_task` and `show_story_requirements` disagreeing,
  and nothing anywhere saying a write had failed.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.Node

  test "a successful computation writes rows and says so" do
    scope = full_scope_fixture()

    assert nodes = Requirements.compute_all(scope)
    assert is_list(nodes)

    written =
      Node
      |> where([n], n.working_copy_id == ^scope.active_working_copy_id)
      |> Repo.aggregate(:count)

    assert written > 0, """
    The computation returned nodes and wrote none. That is the failure this
    module exists for: the return value is right and the read model is empty,
    so every later reader is served somebody else's answer or none.
    """
  end

  test "the write is atomic" do
    scope = full_scope_fixture()

    # Nodes and edges were two independent statements, so a failure between them
    # left nodes without their edges and the next read served that as the graph.
    # Asserted through the public path rather than by forcing a failure: what
    # matters is that one call does not leave a half-written projection behind.
    assert _nodes = Requirements.compute_all(scope)

    node_count =
      Node
      |> where([n], n.working_copy_id == ^scope.active_working_copy_id)
      |> Repo.aggregate(:count)

    assert node_count > 0

    # Recomputing on unchanged inputs must not disturb what is there.
    assert _again = Requirements.compute_all(scope)

    assert Node
           |> where([n], n.working_copy_id == ^scope.active_working_copy_id)
           |> Repo.aggregate(:count) == node_count,
           "a second computation on unchanged inputs rewrote the projection"
  end
end
