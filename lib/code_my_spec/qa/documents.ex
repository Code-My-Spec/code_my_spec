defmodule CodeMySpec.Qa.Documents do
  @moduledoc "Project scoped QA document validation and access to the generic document store."

  alias CodeMySpec.Documents, as: Parser
  alias CodeMySpec.Documents.Stored
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  @types ~w(qa_plan qa_journey_plan qa_story_brief)

  def get(%Scope{active_project_id: project_id}, type, story_number \\ nil) do
    with {:ok, number} <- validate_key(type, story_number) do
      {:ok,
       Repo.get_by(Stored, project_id: project_id, document_type: type, story_number: number)}
    end
  end

  def put(%Scope{active_project_id: project_id} = scope, type, story_number, content)
      when is_binary(content) do
    with {:ok, number} <- validate_key(type, story_number),
         :ok <- validate_story(scope, type, number),
         {:ok, _parsed} <- Parser.create_dynamic_document(content, type) do
      current =
        Repo.get_by(Stored, project_id: project_id, document_type: type, story_number: number)

      attrs = %{
        project_id: project_id,
        document_type: type,
        story_number: number,
        content: content
      }

      changeset = Stored.changeset(current || %Stored{}, attrs)
      if current, do: Repo.update(changeset), else: Repo.insert(changeset)
    end
  end

  def put(_scope, _type, _number, _content), do: {:error, "content must be markdown text"}

  @doc "Preserve a legacy QA file exactly during the one-time import."
  def put_legacy(%Scope{active_project_id: project_id}, type, story_number, content)
      when is_binary(content) do
    with {:ok, number} <- validate_key(type, story_number) do
      %Stored{}
      |> Stored.changeset(%{
        project_id: project_id,
        document_type: type,
        story_number: number,
        content: content
      })
      |> Repo.insert()
    end
  end

  defp validate_key(type, number) when type in ["qa_plan", "qa_journey_plan"] and is_nil(number),
    do: {:ok, 0}

  defp validate_key("qa_story_brief", number) when is_integer(number) and number > 0,
    do: {:ok, number}

  defp validate_key(type, _number) when type in @types,
    do: {:error, "invalid story_number for #{type}"}

  defp validate_key(type, _number), do: {:error, "unknown document type: #{inspect(type)}"}

  defp validate_story(_scope, type, _number) when type != "qa_story_brief", do: :ok

  defp validate_story(scope, _type, number) do
    if Stories.get_story_by_number(scope, number),
      do: :ok,
      else: {:error, "Story #{number} not found in this project"}
  end
end
