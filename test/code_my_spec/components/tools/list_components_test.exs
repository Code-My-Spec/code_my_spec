defmodule CodeMySpec.Components.Tools.ListComponentsTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "ListComponents tool" do
    test "executes with valid params and scope" do
      scope = full_scope_fixture()
      params = %{project_id: "project-123"}
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "list_components",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert {_, _} = response
    end
  end
end
