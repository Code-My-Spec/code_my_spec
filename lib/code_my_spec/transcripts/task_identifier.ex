defmodule CodeMySpec.Transcripts.TaskIdentifier do
  @moduledoc "Extract task identity from a subagent transcript."

  alias CodeMySpec.AgentTasks.TaskMarker
  alias CodeMySpec.Transcripts
  alias CodeMySpec.Transcripts.ClaudeCode.Entry

  @spec identify(String.t()) :: {:ok, %{type: String.t(), component: String.t()}} | :none
  def identify(transcript_path) do
    with {:ok, transcript} <- Transcripts.parse(transcript_path),
         {:ok, marker} <- find_marker_in_entries(transcript.entries) do
      {:ok, marker}
    else
      _ -> :none
    end
  end

  defp find_marker_in_entries(entries) do
    Enum.find_value(entries, :none, fn entry ->
      case extract_from_entry(entry) do
        {:ok, _} = result -> result
        :none -> nil
      end
    end)
  end

  defp extract_from_entry(entry) do
    case Entry.content(entry) do
      text when is_binary(text) -> TaskMarker.extract(text)
      blocks when is_list(blocks) -> extract_from_blocks(blocks)
      _ -> :none
    end
  end

  defp extract_from_blocks(blocks) do
    Enum.find_value(blocks, :none, fn
      %{"type" => "text", "text" => text} ->
        case TaskMarker.extract(text) do
          {:ok, _} = result -> result
          :none -> nil
        end

      _ ->
        nil
    end)
  end
end
