defmodule CodeMySpec.McpServers.Requirements.Tools.ListRequirementsTest do
  use ExUnit.Case, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.RequirementsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "execute/2" do
    test "returns requirements grouped by entity with satisfaction status" do
      # Asserts on a `spec_file` node, which only exists when specs are
      # required — a fresh project defaults to spex and code only.
      scope = CodeMySpec.ConfigurationsFixtures.require_all!(full_scope_fixture())
      component = component_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      # Seed a spec file to satisfy spec_file for this component
      requirement_fixture(scope, component, %{name: "spec_file", satisfied: true})

      assert {:reply, response, ^frame} = ListRequirements.execute(%{}, frame)

      refute response.isError
      content = response_text(response)

      assert content =~ "Project Requirements"
      assert content =~ "spec_file"
      assert content =~ "project_setup"
    end

    test "returns project-level requirements even with no components" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ListRequirements.execute(%{}, frame)

      refute response.isError
      content = response_text(response)
      assert content =~ "project_setup"
    end

    test "returns error without valid scope" do
      frame = %Frame{assigns: %{}}

      assert {:reply, response, ^frame} = ListRequirements.execute(%{}, frame)
      assert response.isError
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
