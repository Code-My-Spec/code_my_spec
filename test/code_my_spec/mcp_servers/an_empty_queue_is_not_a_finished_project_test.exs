defmodule CodeMySpec.McpServers.AnEmptyQueueIsNotAFinishedProjectTest do
  @moduledoc """
  What an agent is told when its own queue is empty.

  Watched on dev, 2026-09-07: a coding agent on a project with three unsatisfied
  requirements called `get_next_requirement` and was told "All requirements
  satisfied". Stopping was right — `issues_resolved` is coding's and sits behind
  `issues_triaged`, which is product's — but the sentence says the project is
  finished, and the person reading it had no way from there to tell that from a
  graph nobody has any work in.

  Three states, not two: nothing computed at all, nothing actionable for
  anybody, and work that exists and belongs to another role. The third used to
  report itself as the second.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.Requirements.RequirementsMapper

  defp node(name, role), do: %{name: name, role: role}

  defp text(response), do: response_text(response)

  test "says the queue is empty rather than the project finished" do
    said =
      RequirementsMapper.nothing_for_this_role_response(
        [node("issues_triaged", :product)],
        :coding
      )
      |> text()

    assert said =~ "Nothing for coding"

    refute said =~ "All requirements satisfied",
           "this is the sentence that read as a finished project to the person watching"
  end

  # The actionable half. An agent that knows product holds the work can say what
  # it is waiting for, and whoever reads it can see that starting product is the
  # thing to do.
  test "names the role that holds the work, and what it is" do
    said =
      RequirementsMapper.nothing_for_this_role_response(
        [node("issues_triaged", :product), node("work_dispatched", :main)],
        :coding
      )
      |> text()

    assert said =~ "product"
    assert said =~ "issues_triaged"
    assert said =~ "main"
    assert said =~ "work_dispatched"
  end

  test "counts what is waiting, so an empty queue is not read as an empty graph" do
    said =
      RequirementsMapper.nothing_for_this_role_response(
        [node("a", :product), node("b", :product), node("c", :qa)],
        :coding
      )
      |> text()

    assert said =~ "3 actionable"
  end

  # A requirement no role owns — project scaffolding — still has to be named as
  # somebody's rather than dropped, or the count and the list disagree.
  test "a requirement with no role is still accounted for" do
    said = RequirementsMapper.nothing_for_this_role_response([node("scaffold", nil)], :coding)

    assert text(said) =~ "unassigned"
  end

  # The agent must not be left thinking it has to poll. `wake_roles/2` is what
  # brings it back, and saying so is the difference between a stop and a spin.
  test "says what will bring it back" do
    said = RequirementsMapper.nothing_for_this_role_response([node("x", :product)], :coding)

    assert text(said) =~ "woken"
  end
end
