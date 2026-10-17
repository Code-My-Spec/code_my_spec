defmodule CodeMySpec.Embeddings.ToolsTest do
  use ExUnit.Case, async: false

  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Embeddings.TestBackend
  alias CodeMySpec.McpServers.CodeMode
  alias CodeMySpec.ToolLibrary
  alias CodeMySpec.Users.Scope

  setup do
    previous = Application.fetch_env(:code_my_spec, :embeddings_backend)
    Application.put_env(:code_my_spec, :embeddings_backend, TestBackend)
    TestBackend.reset()

    on_exit(fn -> restore_backend(previous) end)

    scope = %Scope{active_project_id: Ecto.UUID.generate()}
    {:ok, scope: scope}
  end

  defp restore_backend({:ok, backend}),
    do: Application.put_env(:code_my_spec, :embeddings_backend, backend)

  defp restore_backend(:error), do: Application.delete_env(:code_my_spec, :embeddings_backend)

  test "the tool retains its original MCP contract" do
    original =
      "test/fixtures/tool_contracts/embeddings.json"
      |> File.read!()
      |> Jason.decode!()

    actual =
      ToolLibrary.registrations()
      |> Enum.filter(&(&1.name == "semantic_search"))
      |> Enum.map(&Map.take(&1, [:name, :description, :input_schema]))
      |> Jason.encode!()
      |> Jason.decode!()

    assert actual == original
  end

  test "search returns formatted matches from all documentation sources", %{scope: scope} do
    for source <- ~w(knowledge project_knowledge hexdocs:phoenix) do
      {:ok, _} =
        TestBackend.embed_file(scope.active_project_id, source, "guide.md", "LiveView guide")
    end

    assert {:ok, text} = ToolLibrary.run("semantic_search", %{query: "LiveView"}, %{scope: scope})
    assert text =~ "# Search: \"LiveView\""
    assert text =~ "**3 results**"
    assert text =~ "**knowledge/guide.md** (chunk 0)"
    assert text =~ "**project_knowledge/guide.md** (chunk 0)"
    assert text =~ "**hexdocs:phoenix/guide.md** (chunk 0)"
    assert text =~ "LiveView guide"
  end

  test "source filters distinguish all HexDocs from an exact package", %{scope: scope} do
    for source <- ~w(knowledge project_knowledge hexdocs:phoenix hexdocs:ecto) do
      {:ok, _} = TestBackend.embed_file(scope.active_project_id, source, "guide.md", source)
    end

    assert {:ok, all_hex} =
             ToolLibrary.run("semantic_search", %{query: "guide", source: "hexdocs"}, %{
               scope: scope
             })

    assert all_hex =~ "**2 results**"
    assert all_hex =~ "**hexdocs:phoenix/guide.md**"
    assert all_hex =~ "**hexdocs:ecto/guide.md**"
    refute all_hex =~ "**knowledge/guide.md**"

    assert {:ok, package} =
             ToolLibrary.run(
               "semantic_search",
               %{query: "guide", source: "hexdocs:phoenix"},
               %{scope: scope}
             )

    assert package =~ "**1 results**"
    assert package =~ "**hexdocs:phoenix/guide.md**"
    refute package =~ "**hexdocs:ecto/guide.md**"
  end

  test "search respects the result limit and active project", %{scope: scope} do
    for path <- ~w(first.md second.md) do
      {:ok, _} = TestBackend.embed_file(scope.active_project_id, "knowledge", path, "LiveView")
    end

    {:ok, _} = TestBackend.embed_file(Ecto.UUID.generate(), "knowledge", "private.md", "LiveView")

    assert {:ok, text} =
             ToolLibrary.run("semantic_search", %{query: "LiveView", limit: 1}, %{scope: scope})

    assert text =~ "**1 results**"
    refute text =~ "private.md"
  end

  test "an empty search explains automatic reconciliation", %{scope: scope} do
    assert {:ok, text} = ToolLibrary.run("semantic_search", %{query: "missing"}, %{scope: scope})
    assert text =~ "**0 results**"
    assert text =~ "No matches found"
    assert text =~ "there's nothing to run"
  end

  test "unavailable embeddings names the working fallback instead of inviting retries", %{
    scope: scope
  } do
    Application.delete_env(:code_my_spec, :embeddings_backend)

    assert {:error, text} =
             ToolLibrary.run("semantic_search", %{query: "LiveView"}, %{scope: scope})

    assert text =~ "no query will work here"
    assert text =~ "retrying or rephrasing will not help"
    assert text =~ "`list_knowledge` and `read_knowledge` do work"
  end

  test "missing project and invalid arguments are refused before search" do
    assert {:error, missing_project} =
             ToolLibrary.run("semantic_search", %{query: "LiveView"}, %{})

    assert missing_project =~ "Active project is not set"
    assert {:error, invalid} = ToolLibrary.run("semantic_search", %{}, %{})
    assert invalid =~ "invalid arguments"
  end

  test "code mode exposes the migrated tool without changing its name", %{scope: scope} do
    assert {:ok, text} =
             CodeMode.catalog(scope)["semantic_search"].invoke.(%{"query" => "LiveView"})

    assert text =~ "**0 results**"
    assert Enum.any?(RoleProfile.roles(), &RoleProfile.carries?(&1, "semantic_search"))
  end
end
