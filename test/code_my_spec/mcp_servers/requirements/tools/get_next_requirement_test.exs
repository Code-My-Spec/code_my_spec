defmodule CodeMySpec.McpServers.Requirements.Tools.GetNextRequirementTest do
  use ExUnit.Case, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.WorkingCopies
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
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

      assert {:reply, response, ^frame} = GetNextRequirement.execute(%{}, frame)

      refute response.isError
      content = response_text(response)

      assert content =~ "Status: unavailable"
      refute content =~ "start_task"
      refute content =~ "All requirements satisfied"
    end

    test "returns init checklist when no project is linked" do
      frame = %Frame{assigns: %{}}

      assert {:reply, response, ^frame} = GetNextRequirement.execute(%{}, frame)
      refute response.isError
      assert is_nil(response.structured_content)
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

      assert {:reply, response, _} =
               GetNextRequirement.execute(%{story_number: ctx.other.number}, frame)

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

      assert {:reply, response, _} =
               GetNextRequirement.execute(%{story_number: ctx.other.number}, frame)

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

      assert {:reply, response, _} = GetNextRequirement.execute(%{}, frame)
      refute response_text(response) =~ "Status: unavailable"
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    Enum.map_join(protocol["content"], "\n", & &1["text"])
  end
end
