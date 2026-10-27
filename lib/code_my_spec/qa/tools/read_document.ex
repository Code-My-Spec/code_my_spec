defmodule CodeMySpec.Qa.Tools.ReadDocument do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Qa.Documents

  @impl true
  def name, do: "read_document"

  @impl true
  def description,
    do: "Read a shared QA plan, journey plan, or story brief from the project database."

  @impl true
  def params do
    %{
      document_type:
        {:required,
         {:meta, :string, [description: "qa_plan, qa_journey_plan, or qa_story_brief"]}},
      story_number: {:meta, :integer, [description: "Required for qa_story_brief"]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, document} <-
           Documents.get(scope, params.document_type, Map.get(params, :story_number)),
         false <- is_nil(document) do
      {:ok, document.content}
    else
      true -> {:error, "Document not found"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
