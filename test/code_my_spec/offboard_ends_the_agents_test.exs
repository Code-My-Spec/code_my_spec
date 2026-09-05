defmodule CodeMySpec.OffboardEndsTheAgentsTest do
  @moduledoc """
  Discarding a working copy ends the agents on it.

  Story 964's rule: a working copy is the boundary of the work. John,
  2026-09-04: *"I can keep them through that whole epic and then I can discard
  the working copy and then come up with another one — that's how I need to
  control these boundaries."*

  `offboard/2` counted files, problems and orphaned components and never touched
  an agent, so a discarded copy left its agents running against a directory that
  was no longer this project's — a model held open, a subscription slot held,
  and still spending. Story 961 is the same concern from the other side.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()
    {:ok, _} = CodeMySpecSpex.Fixtures.connect_provider(scope, :openai)

    device = CodeMySpec.DevicesFixtures.device_fixture(scope)
    n = System.unique_integer([:positive])

    # A main checkout first, so the epic's copy is not the project's only one —
    # the main copy holds exactly one agent and a roster of three cannot go
    # there.
    {:ok, main} = WorkingCopies.issue(scope, nil, root: "/tmp/off-main-#{n}", device: device)
    {:ok, _} = WorkingCopies.report_root(main, "/tmp/off-main-#{n}")

    root = "/tmp/off-copy-#{n}"
    {:ok, copy} = WorkingCopies.issue(scope, nil, root: root, device: device, label: "an epic")
    {:ok, copy} = WorkingCopies.report_root(copy, root)

    %{started: started} = Agents.ensure_copy_agents(scope, copy)
    assert length(started) == 3, "the premise needs a staffed copy to discard"

    %{scope: scope, copy: copy}
  end

  test "the copy's agents are stopped", %{scope: scope, copy: copy} do
    {:ok, counts} = WorkingCopies.offboard(scope, copy)

    assert counts.agents_stopped == 3,
           "the copy is gone and its agents were left running against a directory " <>
             "that is no longer this project's. Got: #{inspect(counts)}"

    running =
      scope
      |> Agents.list_agents()
      |> Enum.filter(&(&1.working_copy_id == copy.id and &1.status != :stopped))

    assert running == [],
           "an agent from the discarded copy is still not stopped: #{inspect(running)}"
  end

  test "agents on other copies are left alone", %{scope: scope, copy: copy} do
    before = scope |> Agents.list_agents() |> Enum.reject(&(&1.working_copy_id == copy.id))

    {:ok, _counts} = WorkingCopies.offboard(scope, copy)

    after_ =
      scope
      |> Agents.list_agents()
      |> Enum.reject(&(&1.working_copy_id == copy.id))
      |> Enum.filter(&(&1.status != :stopped))

    assert length(after_) == length(Enum.filter(before, &(&1.status != :stopped))),
           "discarding one copy stopped an agent on another. Story 1023's rule is " <>
             "that stopping one agent leaves every other agent on that project " <>
             "running, and a copy is a smaller boundary than a project, not a bigger one."
  end

  test "the counts still report what was removed", %{scope: scope, copy: copy} do
    {:ok, counts} = WorkingCopies.offboard(scope, copy)

    for key <- [:files, :problems, :components] do
      assert Map.has_key?(counts, key),
             "the agent counts replaced what offboard already reported rather than " <>
               "joining it — the person offboarding still needs to know what went"
    end
  end
end
