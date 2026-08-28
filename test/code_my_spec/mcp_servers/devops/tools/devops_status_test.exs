defmodule CodeMySpec.McpServers.Devops.Tools.DevopsStatusTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Configurations
  alias CodeMySpec.McpServers.Devops.Tools.DevopsStatus
  alias CodeMySpec.Resources
  alias Anubis.Server.Frame
  alias Anubis.Server.Response

  setup do
    scope = full_scope_fixture()
    %{scope: scope, project: scope.active_project}
  end

  describe "execute/2" do
    # The whole point: a real incident. A project whose own devops was still
    # :off got back an unrelated project's checklist instead of an answer
    # about itself, because Resources.report/1 is deliberately account-wide
    # (the cross-project dangling checks need to see everything, which is
    # right for a human on /app/resources) and nothing here checked which
    # project was actually asking before handing that back to a harness
    # caller scoped to one project's work.
    test "refuses rather than reporting on a sibling project when this project's devops is off",
         %{scope: scope, project: project} do
      sibling = project_fixture(scope, %{name: "Sibling Project"})
      sibling_scope = Resources.project_scope(scope, sibling)
      {:ok, _} = Configurations.update(sibling_scope, %{devops: :prod})

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = DevopsStatus.execute(%{}, frame)

      assert response.isError == true
      text = response_text(response)
      assert text =~ "devops is off"
      assert text =~ project.name
      refute text =~ "Sibling Project"
    end

    test "reports for real once this project's own devops is on", %{scope: scope, project: project} do
      {:ok, _} = Configurations.update(scope, %{devops: :prod})

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = DevopsStatus.execute(%{}, frame)

      assert response.isError == false
      assert response_text(response) =~ project.name
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
