defmodule CodeMySpec.McpServers.Requirements.Tools.ShowRequirementTest do
  use ExUnit.Case, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.RequirementsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Requirements.Tools.ShowRequirement
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "execute/2" do
    test "surfaces the checker's reason when the requirement is not satisfied" do
      scope = CodeMySpec.ConfigurationsFixtures.require_all!(full_scope_fixture())
      component = component_fixture(scope)

      requirement_fixture(scope, component, %{name: "spec_file", satisfied: false})

      # Reads serve rows; the write path computes them.
      CodeMySpec.Requirements.recompute(scope)

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               ShowRequirement.execute(
                 %{name: "spec_file", entity_type: "component", entity_id: component.id},
                 frame
               )

      content = response_text(response)
      assert content =~ "**Status:** Not satisfied"
      assert content =~ "**Why:** spec file missing"
    end

    test "omits the reason line when the requirement is satisfied" do
      scope = CodeMySpec.ConfigurationsFixtures.require_all!(full_scope_fixture())
      component = component_fixture(scope)

      requirement_fixture(scope, component, %{name: "spec_file", satisfied: true})

      # Reads serve rows; the write path computes them.
      CodeMySpec.Requirements.recompute(scope)

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               ShowRequirement.execute(
                 %{name: "spec_file", entity_type: "component", entity_id: component.id},
                 frame
               )

      content = response_text(response)
      assert content =~ "**Status:** Satisfied"
      refute content =~ "**Why:**"
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
