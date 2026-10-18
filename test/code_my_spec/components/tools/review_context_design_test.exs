defmodule CodeMySpec.Components.Tools.ReviewContextDesignTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias Ecto.Adapters.SQL.Sandbox
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "ReviewContextDesign tool" do
    test "executes and returns prompt response with valid scope" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "review_context_design",
          %{},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert {:ok, content_text} = response
      assert String.contains?(content_text, "Context Design Review")
    end
  end
end
