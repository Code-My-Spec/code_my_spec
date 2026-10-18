defmodule CodeMySpec.Components.Tools.DeleteComponentTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias Ecto.Adapters.SQL.Sandbox
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "DeleteComponent tool" do
    test "executes with valid params and scope" do
      scope = full_scope_fixture()
      component = component_fixture(scope)
      params = %{component_id: component.id}

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "delete_component",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert {_, _} = response
      assert {:ok, json_content} = response
      content = Jason.decode!(json_content)
      assert content["id"] == component.id
    end

    test "returns error for non-existent component" do
      scope = full_scope_fixture()
      params = %{component_id: "00000000-0000-0000-0000-000000000000"}

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "delete_component",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert {_, _} = response
      assert match?({:error, _}, response)
    end

    test "returns error for invalid scope" do
      component = component_fixture(full_scope_fixture())
      params = %{component_id: component.id}

      frame = %Frame{assigns: %{}}

      response =
        ToolLibrary.run(
          "delete_component",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert {_, _} = response
      assert match?({:error, _}, response)
    end
  end
end
