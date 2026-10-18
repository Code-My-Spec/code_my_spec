defmodule CodeMySpec.Components.Tools.StartContextDesignTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias Ecto.Adapters.SQL.Sandbox
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "StartContextDesign tool" do
    test "executes and returns prompt response with valid scope" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "start_context_design",
          %{},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert {:ok, content_text} = response
      assert String.contains?(content_text, "expert Elixir architect")
    end
  end
end
