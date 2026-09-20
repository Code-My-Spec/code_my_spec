defmodule CodeMySpec.McpServers.Requirements.Tools.GetNextRequirementTest do
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
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

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
