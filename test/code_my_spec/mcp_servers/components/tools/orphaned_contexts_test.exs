defmodule CodeMySpec.McpServers.Components.Tools.OrphanedContextsTest do
  use ExUnit.Case, async: true
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.OrphanedContexts
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "OrphanedContexts tool" do
    test "executes with valid params and scope" do
      scope = full_scope_fixture()
      params = %{project_id: "project-123"}
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = OrphanedContexts.execute(params, frame)
      assert response.type == :tool
    end
  end
end
