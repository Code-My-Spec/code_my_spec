defmodule CodeMySpec.McpServers.Components.Tools.CreateComponentTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Components.Tools.CreateComponent
  alias Anubis.Server.Frame
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "CreateComponent tool" do
    test "executes with valid params and scope" do
      scope = full_scope_fixture()

      params = %{
        name: "LoginButton",
        type: "context",
        module_name: "MyApp.LoginButton",
        description: "A button component for user login"
      }

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = CreateComponent.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false
    end
  end

  describe "schema validation (JSON-RPC entry path)" do
    # Regression: previously the schema produced `{:string, {:enum, list}}`,
    # which Peri can't validate against, so every live MCP call returned
    # -32602 Invalid params. Validate via the same pipeline used by the
    # tools handler.
    setup do
      cleaned =
        CreateComponent.__mcp_raw_schema__()
        |> Anubis.Server.Component.__clean_schema_for_peri__()

      %{cleaned: cleaned}
    end

    test "accepts every documented type", %{cleaned: cleaned} do
      for type <- ~w(context coordination_context live_context schema behaviour
                     json liveview liveview_component controller module) do
        params = %{"name" => "F", "type" => type, "module_name" => "MyApp.F"}
        assert {:ok, _} = Peri.validate(cleaned, params), "type #{inspect(type)} should validate"
      end
    end

    test "rejects an unknown type with a clear error", %{cleaned: cleaned} do
      params = %{"name" => "F", "type" => "bogus", "module_name" => "MyApp.F"}
      assert {:error, [%Peri.Error{path: [:type]} | _]} = Peri.validate(cleaned, params)
    end

    test "accepts a UUID parent_component_id", %{cleaned: cleaned} do
      params = %{
        "name" => "F",
        "type" => "module",
        "module_name" => "MyApp.F",
        "parent_component_id" => "22222222-2222-2222-2222-222222222222"
      }

      assert {:ok, _} = Peri.validate(cleaned, params)
    end
  end
end
