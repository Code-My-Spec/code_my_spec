defmodule CodeMySpec.Qa.Tools.WriteDocument do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Qa.Documents
  alias CodeMySpec.Requirements

  @impl true
  def name, do: "write_document"

  @impl true
  def description,
    do:
      "Validate and replace a shared QA document in the project database. Invalid edits preserve the current document."

  @impl true
  def params do
    %{
      document_type:
        {:required,
         {:meta, :string, [description: "qa_plan, qa_journey_plan, or qa_story_brief"]}},
      story_number: {:meta, :integer, [description: "Required for qa_story_brief"]},
      content: {:required, {:meta, :string, [description: "Complete markdown document"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, document} <-
           Documents.put(
             scope,
             params.document_type,
             Map.get(params, :story_number),
             params.content
           ) do
      Requirements.recompute(scope)
      {:ok, "Saved #{document.document_type} document."}
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
