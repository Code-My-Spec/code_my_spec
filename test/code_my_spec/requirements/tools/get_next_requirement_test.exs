defmodule CodeMySpec.Requirements.Tools.GetNextRequirementTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.WorkingCopies
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  test "discovery answers during a restart rebuild and recovers once the writer is ready" do
    scope = full_scope_fixture()
    alias CodeMySpec.Requirements.IncrementalGraph

    {:ok, pid} = IncrementalGraph.ensure_projecting(scope)
    :ok = IncrementalGraph.settle(scope.active_project_id)

    CodeMySpecTest.SuspendedProjector.while_suspended(pid, fn ->
      started = System.monotonic_time(:millisecond)
      assert {:ok, text} = ToolLibrary.run("get_next_requirement", %{}, %{scope: scope})
      assert System.monotonic_time(:millisecond) - started < 3_000
      assert text =~ "Status: ready"
      assert text =~ "requirement_name=`personas_complete`"
      refute text =~ "retry in 5 s"
      refute text =~ "All requirements satisfied"
    end)

    :ok = IncrementalGraph.settle(scope.active_project_id)
    assert {:ok, text} = ToolLibrary.run("get_next_requirement", %{}, %{scope: scope})
    refute text =~ "retry in 5 s"
  end

  test "an outstanding offer remains discoverable while the graph writer is suspended" do
    alias CodeMySpec.Agents.Offers
    alias CodeMySpec.Requirements.IncrementalGraph

    scope = full_scope_fixture()

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: CodeMySpec.DevicesFixtures.device_fixture(scope))

    scope = %{scope | active_working_copy_id: copy.id}
    story = story_fixture(scope)

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        working_copy: "/tmp/rebuild-offer",
        role: :coding,
        working_copy_id: copy.id
      })

    {:ok, _} = Agents.assign_team(scope, copy.id, story.id)
    {:ok, pid} = IncrementalGraph.ensure_projecting(scope)
    :ok = IncrementalGraph.settle(scope.active_project_id)

    offer =
      Offers.record(nil, agent, :work, {"requirement", "story:#{story.number}:ready_for_qa"})

    context = %{scope: scope, agent_id: agent.id}

    CodeMySpecTest.SuspendedProjector.while_suspended(pid, fn ->
      assert {:ok, text} = ToolLibrary.run("get_next_requirement", %{}, context)
      assert text =~ "requirement_name=`ready_for_qa`"
      assert text =~ "entity_type=`story`, entity_id=`#{story.number}`"
      assert text =~ offer.id
      refute text =~ "No work was offered"

      assert {:ok, mismatch} =
               ToolLibrary.run("get_next_requirement", %{story_number: story.number + 1}, context)

      refute mismatch =~ "requirement_name=`ready_for_qa`"
    end)
  end

  describe "execute/2" do
    # A session that names no checkout has nothing to answer for, and answering
    # it with the project's work hands an agent a queue it has no tree to build
    # in. A copy *with* a checkout and no selected story is a different case and
    # does get the project's work — see `StoryExecution.from_copy/5`.
    test "a session with no working copy is unavailable rather than given project work" do
      scope = full_scope_fixture()
      # Reads serve rows; the write path computes them.
      CodeMySpec.Requirements.recompute(scope)

      frame = %Frame{assigns: %{current_scope: %{scope | active_working_copy_id: nil}}}

      response =
        ToolLibrary.run(
          "get_next_requirement",
          %{},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
      content = response_text(response)

      assert content =~ "Status: unavailable"
      refute content =~ "start_task"
      refute content =~ "All requirements satisfied"
    end

    test "returns init checklist when no project is linked" do
      frame = %Frame{assigns: %{}}

      response =
        ToolLibrary.run(
          "get_next_requirement",
          %{},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
      assert response_text(response) =~ "Initialization"
      assert response_text(response) =~ "get_next_requirement"
    end
  end

  # `StoryExecution.selected/3` answered `:none` for two different situations —
  # "this copy chose nothing" and "you named a story that is not the chosen
  # one" — and `:none` means "answer for the whole project". So asking for
  # story B while story A was active handed back the project's entire queue,
  # byte-identical to asking with no selection at all.
  #
  # Found by dogfooding against a live project, not by this suite: nothing here
  # reached `read/3`'s routing, only `from_graph/5` beneath it. The tool's own
  # moduledoc has always said "an explicit story must agree with the working
  # copy's active assignment", and `selected/3`'s comment said a mismatch must
  # not widen the answer. Only the code disagreed.
  describe "an explicit story_number never widens the answer" do
    setup do
      scope = full_scope_fixture()

      {:ok, copy} =
        WorkingCopies.issue(scope, nil, device: CodeMySpec.DevicesFixtures.device_fixture(scope))

      scope = %{scope | active_working_copy_id: copy.id}
      active = story_fixture(scope)
      other = story_fixture(scope)

      {:ok, _coding} =
        AgentsRepository.create_agent(scope, %{
          engine: :alloy,
          provider: "zai",
          working_copy: "/tmp/a-copy",
          role: :coding,
          working_copy_id: copy.id
        })

      {:ok, _} = Agents.assign_team(scope, copy.id, active.id)
      CodeMySpec.Requirements.recompute(scope)

      %{scope: scope, active: active, other: other}
    end

    test "a story that is not the active one is refused rather than widened", ctx do
      frame = %Frame{assigns: %{current_scope: ctx.scope}}

      response =
        ToolLibrary.run(
          "get_next_requirement",
          %{story_number: ctx.other.number},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      content = response_text(response)

      assert content =~ "Status: unavailable"

      assert content =~ "active story (#{ctx.active.number})",
             "the refusal has to name the story this copy is actually on, or the agent " <>
               "cannot tell a refusal from an empty project"

      # The header is no use here: `# Story scope` is what the mapper prints for
      # any storyless result, refusal and project answer alike. What separates
      # them is whether anything was offered — the widening handed back a whole
      # wave of other stories' work, so an empty offer is the assertion that
      # actually holds the line. Same idiom criterion 3606 uses.
      refute content =~ "requirement_name=`",
             "a refusal must offer no work; the bug offered the project's entire queue"
    end

    test "a story_number on a copy that has chosen nothing is refused, not answered for the project",
         ctx do
      {:ok, _} = Agents.assign_team(ctx.scope, ctx.scope.active_working_copy_id, nil)
      frame = %Frame{assigns: %{current_scope: ctx.scope}}

      response =
        ToolLibrary.run(
          "get_next_requirement",
          %{story_number: ctx.other.number},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      content = response_text(response)
      assert content =~ "Status: unavailable"
      refute content =~ "requirement_name=`"
    end

    # The other half, and the reason the fix splits on whether the caller named
    # a story rather than on what the copy holds: asked bare, a copy with no
    # selection is still answered for the project. That is where the fourteen
    # project-level requirements reach anybody, and story 1005's rule.
    test "asked bare, a copy with no active story is still answered for the project", ctx do
      {:ok, _} = Agents.assign_team(ctx.scope, ctx.scope.active_working_copy_id, nil)
      frame = %Frame{assigns: %{current_scope: ctx.scope}}

      response =
        ToolLibrary.run(
          "get_next_requirement",
          %{},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      refute response_text(response) =~ "Status: unavailable"
    end
  end

  defp response_text({_status, text}) when is_binary(text), do: text

  defp response_text({_status, text}), do: text
end
