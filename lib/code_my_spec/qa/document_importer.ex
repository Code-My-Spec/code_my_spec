defmodule CodeMySpec.Qa.DocumentImporter do
  @moduledoc "Imports legacy QA plans and briefs, removing only successfully imported files."

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.Qa.Documents
  alias CodeMySpec.Documents.Stored

  @plan ".code_my_spec/qa/plan.md"
  @journey ".code_my_spec/qa/journey_plan.md"
  @brief_glob ".code_my_spec/qa/*/brief.md"

  def import(scope, env) do
    paths = [@plan, @journey | ExecutionContexts.glob(env, @brief_glob)]
    {:ok, Enum.map(paths, &import_path(scope, env, &1))}
  end

  defp import_path(scope, env, path) do
    with {:ok, content} <- ExecutionContexts.read_file(env, path),
         {:ok, {type, number}} <- key(path),
         {:ok, nil} <- Documents.get(scope, type, number),
         {:ok, document} <- Documents.put_legacy(scope, type, number, content),
         :ok <- ExecutionContexts.delete_file(env, path) do
      %{path: path, status: :imported, document_id: document.id}
    else
      {:ok, %Stored{} = document} ->
        case ExecutionContexts.read_file(env, path) do
          {:ok, file_content} when file_content == document.content ->
            case ExecutionContexts.delete_file(env, path) do
              :ok -> %{path: path, status: :already_imported, document_id: document.id}
              {:error, reason} -> %{path: path, status: :refused, reason: inspect(reason)}
            end

          _ ->
            %{path: path, status: :already_imported, document_id: document.id}
        end

      {:error, :enoent} ->
        %{path: path, status: :missing}

      {:error, reason} ->
        %{path: path, status: :refused, reason: inspect(reason)}
    end
  end

  defp key(@plan), do: {:ok, {"qa_plan", nil}}
  defp key(@journey), do: {:ok, {"qa_journey_plan", nil}}

  defp key(path) do
    case Regex.run(~r{^\.code_my_spec/qa/(\d+)/brief\.md$}, path) do
      [_, number] -> {:ok, {"qa_story_brief", String.to_integer(number)}}
      _ -> {:error, :unknown_path}
    end
  end
end
