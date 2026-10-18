defmodule CodeMySpec.Components.Tools.UpdateComponentTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias Ecto.Adapters.SQL.Sandbox
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "UpdateComponent tool" do
    test "executes with valid params and scope" do
      scope = full_scope_fixture()
      component = component_fixture(scope)

      params = %{
        component_id: component.id,
        name: "Updated Component Name",
        description: "Updated description"
      }

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "update_component",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert {_, _} = response
      assert match?({:ok, _}, response)
    end
  end
end
