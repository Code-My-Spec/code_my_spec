defmodule CodeMySpec.Stories.Tools.CreateStoryTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias Ecto.Adapters.SQL.Sandbox
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "CreateStory tool" do
    test "executes with valid params and scope" do
      params = %{
        title: "User Login",
        description: "As a user I want to login",
        acceptance_criteria: ["User can enter credentials", "System validates credentials"]
      }

      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "create_story",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
    end
  end
end
