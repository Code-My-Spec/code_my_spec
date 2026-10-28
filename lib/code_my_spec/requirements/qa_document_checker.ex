defmodule CodeMySpec.Requirements.QaDocumentChecker do
  @moduledoc "Checks the shared QA documents that gate project QA work."

  alias CodeMySpec.Qa.Documents

  def plan?(scope, _entity), do: document?(scope, "qa_plan")
  def journey_plan?(scope, _entity), do: document?(scope, "qa_journey_plan")

  defp document?(scope, type) do
    case Documents.get(scope, type) do
      {:ok, %{content: content}} when is_binary(content) and content != "" ->
        {true, %{status: "#{type} document exists and is valid"}}

      _ ->
        {false, %{reason: "#{type} document missing"}}
    end
  end
end
