defmodule CodeMySpec.Requirements.Tools.ListRequirementsTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.RequirementsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "execute/2" do
    test "returns requirements grouped by entity with satisfaction status" do
      # Read the surviving component implementation requirement.
      scope = CodeMySpec.ConfigurationsFixtures.ensure_configuration!(full_scope_fixture())
      component = component_fixture(scope)
      # Reads serve rows; the write path computes them.
      CodeMySpec.Requirements.recompute(scope)

      frame = %Frame{assigns: %{current_scope: scope}}

      # Seed an implementation file to satisfy implementation_file for this component
      requirement_fixture(scope, component, %{name: "implementation_file", satisfied: true})

      response =
        ToolLibrary.run(
          "list_requirements",
          %{},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
      content = response_text(response)

      assert content =~ "Project Requirements"
      assert content =~ "implementation_file"
      assert content =~ "personas_complete"
    end

    test "returns project-level requirements even with no components" do
      scope = full_scope_fixture()
      # Reads serve rows; the write path computes them.
      CodeMySpec.Requirements.recompute(scope)

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "list_requirements",
          %{},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
      content = response_text(response)
      assert content =~ "personas_complete"
    end

    test "entity_id narrows to one entity instead of being silently ignored (69b418e0)" do
      scope = CodeMySpec.ConfigurationsFixtures.ensure_configuration!(full_scope_fixture())
      one = component_fixture(scope)
      other = component_fixture(scope)
      CodeMySpec.Requirements.recompute(scope)

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "list_requirements",
          %{entity_type: "component", entity_id: one.id},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
      content = response_text(response)

      assert content =~ one.module_name
      refute content =~ other.module_name
    end

    test "returns error without valid scope" do
      frame = %Frame{assigns: %{}}

      response =
        ToolLibrary.run(
          "list_requirements",
          %{},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
    end
  end

  # 8c1e192c: `run_script` handed every list tool's rendered text straight to
  # Lua, so a script iterating it with `ipairs` got "table expected, got
  # string" instead of rows.
  describe "script_result/2" do
    test "returns requirement rows as data rather than rendered text" do
      scope = full_scope_fixture()
      CodeMySpec.Requirements.recompute(scope)

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:ok, rows} =
               ToolLibrary.data(
                 "list_requirements",
                 %{},
                 Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
               )

      assert Enum.any?(rows, &(&1["name"] == "personas_complete"))
    end
  end

  defp response_text({_status, text}) when is_binary(text), do: text

  defp response_text({_status, text}), do: text
end
