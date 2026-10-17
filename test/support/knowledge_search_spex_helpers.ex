defmodule CodeMySpecSpex.KnowledgeSearchHelpers do
  @moduledoc """
  What an agent sees when it searches framework knowledge (story 1061): the
  `semantic_search` tool, read the way the agent reads it.
  """

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures

  @doc "The paths `semantic_search` over framework knowledge cites, for this scope."
  @spec knowledge_paths(map()) :: [String.t()]
  def knowledge_paths(scope) do
    {:ok, response} =
      ToolLibrary.run(
        "semantic_search",
        %{query: "framework guidance", source: "knowledge", limit: 50},
        %{scope: scope}
      )

    ~r/^\*\*knowledge\/(.+?)\*\* \(chunk \d+\)/m
    |> Regex.scan(response, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "The search text an agent gets back for framework knowledge."
  @spec knowledge_text(map()) :: String.t()
  def knowledge_text(scope) do
    {:ok, response} =
      ToolLibrary.run(
        "semantic_search",
        %{query: "framework guidance", source: "knowledge", limit: 50},
        %{scope: scope}
      )

    response
  end

  @doc "A second project on the same account, as its own scope."
  @spec another_project(map()) :: map()
  def another_project(context) do
    project = Fixtures.project_fixture_unlinked(context.scope)
    %{context.scope | active_project_id: project.id, active_project: project}
  end

  @doc "A fresh, empty folder standing in for the release's `priv/knowledge`."
  @spec knowledge_folder() :: String.t()
  def knowledge_folder do
    dir = CodeMySpec.TempFile.owned_dir("test")
    dir
  end

  @doc "A release that no longer ships `filename`."
  @spec drop_knowledge_file(String.t(), String.t()) :: :ok
  def drop_knowledge_file(dir, filename), do: File.rm!(Path.join(dir, filename))

  @doc "The embedding batches reported since the last drain, as their texts."
  @spec embedded_texts() :: [String.t()]
  def embedded_texts, do: drain([])

  defp drain(acc) do
    receive do
      {:embedded, texts, _priority} -> drain(acc ++ texts)
    after
      0 -> acc
    end
  end
end
