defmodule CodeMySpec.McpServers.Architecture.Tools.ShowNamespaceHierarchyTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Architecture.Tools.ShowNamespaceHierarchy
  alias Ecto.Adapters.SQL.Sandbox

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
    scope = full_scope_fixture()

    for {name, type} <- [
          {"MyApp", "context"},
          {"MyApp.Accounts", "context"},
          {"MyApp.Accounts.User", "schema"},
          {"MyApp.Accounts.User.Token", "schema"},
          {"MyApp.Billing", "context"}
        ] do
      component_fixture(scope, %{
        name: name |> String.split(".") |> List.last(),
        module_name: name,
        type: type,
        description: "#{name} does its job"
      })
    end

    %{frame: %Frame{assigns: %{current_scope: scope}}}
  end

  defp text(params, frame) do
    {:reply, response, ^frame} = ShowNamespaceHierarchy.execute(params, frame)
    assert response.isError == false
    [%{"type" => "text", "text" => text}] = response.content
    text
  end

  test "two levels by default, counting what the cut hides", %{frame: frame} do
    tree = text(%{}, frame)

    assert tree =~ "MyApp [context] MyApp does its job"
    assert tree =~ "Accounts [context] MyApp.Accounts does its job (+2)"
    assert tree =~ "Billing [context]"
    refute tree =~ "User"
  end

  test "a prefix opens one subtree, its depth counted below the prefix", %{frame: frame} do
    tree = text(%{prefix: "MyApp.Accounts", depth: 1}, frame)

    assert tree =~ "User [schema] MyApp.Accounts.User does its job (+1)"
    refute tree =~ "Billing"
    refute tree =~ "Token"
  end

  test "descriptions can be left out", %{frame: frame} do
    tree = text(%{descriptions: false}, frame)

    assert tree =~ "Accounts [context] (+2)"
    refute tree =~ "does its job"
  end

  test "a prefix with nothing under it says so", %{frame: frame} do
    assert text(%{prefix: "MyApp.Nope"}, frame) == "No components under MyApp.Nope."
  end
end
