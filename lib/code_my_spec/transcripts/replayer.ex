defmodule CodeMySpec.Transcripts.Replayer do
  @moduledoc """
  Replays tool calls from a Claude Code transcript onto a target directory.
  Used for deterministic scenario testing.

  Handles Write, Edit, and select Bash operations (mkdir -p, mv).
  Rewrites absolute paths from the recorded working directory to the
  target directory and applies operations in chronological order.
  """

  alias CodeMySpec.Transcripts
  alias CodeMySpec.Transcripts.ClaudeCode.ToolCall

  @doc """
  Replays operations from a transcript onto a target directory.

  Parses the transcript file, extracts all replayable tool calls
  (Write, Edit, Bash mkdir/mv), rewrites their paths, and applies
  them in order.

  ## Parameters

    - `transcript_path` - Path to the JSONL transcript file
    - `target_dir` - Directory to apply file changes to
    - `opts` - Options
      - `:source_cwd` - Override the recorded cwd for path rewriting

  ## Returns

    - `:ok` on success
    - `{:error, :no_cwd_found}` if no entry has a cwd and none provided via opts
    - `{:error, term()}` on parse or file operation failure
  """
  @spec replay(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def replay(transcript_path, target_dir, opts \\ []) do
    with {:ok, transcript} <- Transcripts.parse(transcript_path),
         {:ok, source_cwd} <- resolve_cwd(transcript, opts) do
      replay_operations(transcript, source_cwd, target_dir)
    end
  end

  @doc """
  Replays operations from an already-parsed transcript.

  Same as `replay/3` but accepts a Transcript struct instead of a file path.
  """
  @spec replay_transcript(Transcripts.ClaudeCode.Transcript.t(), Path.t(), keyword()) ::
          :ok | {:error, term()}
  def replay_transcript(transcript, target_dir, opts \\ []) do
    with {:ok, source_cwd} <- resolve_cwd(transcript, opts) do
      replay_operations(transcript, source_cwd, target_dir)
    end
  end

  defp replay_operations(transcript, source_cwd, target_dir) do
    transcript
    |> Transcripts.get_tool_calls()
    |> Enum.each(&apply_operation(&1, source_cwd, target_dir))

    :ok
  end

  # -- Write: create/overwrite a file

  defp apply_operation(%ToolCall{name: "Write", input: input}, source_cwd, target_dir) do
    path = rewrite_path(input["file_path"], source_cwd, target_dir)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, input["content"])
  end

  # -- Edit: replace first occurrence of old_string with new_string

  defp apply_operation(%ToolCall{name: "Edit", input: input}, source_cwd, target_dir) do
    path = rewrite_path(input["file_path"], source_cwd, target_dir)
    content = File.read!(path)
    new_content = String.replace(content, input["old_string"], input["new_string"], global: false)
    File.write!(path, new_content)
  end

  # -- Bash: extract replayable commands (mkdir -p, mv)

  defp apply_operation(%ToolCall{name: "Bash", input: input}, source_cwd, target_dir) do
    command = input["command"] || ""

    cond do
      mkdir_command?(command) -> apply_mkdir(command, source_cwd, target_dir)
      mv_command?(command) -> apply_mv(command, source_cwd, target_dir)
      true -> :skip
    end
  end

  # -- Everything else: skip

  defp apply_operation(%ToolCall{}, _source_cwd, _target_dir), do: :skip

  # -- Bash: mkdir -p

  defp mkdir_command?(command), do: String.starts_with?(String.trim(command), "mkdir -p ")

  defp apply_mkdir(command, source_cwd, target_dir) do
    command
    |> String.trim()
    |> String.replace_prefix("mkdir -p ", "")
    |> String.split()
    |> Enum.each(fn path ->
      rewritten = rewrite_path(path, source_cwd, target_dir)
      File.mkdir_p!(rewritten)
    end)
  end

  # -- Bash: mv

  defp mv_command?(command) do
    trimmed = String.trim(command)
    String.starts_with?(trimmed, "mv ") and not String.contains?(trimmed, "|")
  end

  defp apply_mv(command, source_cwd, target_dir) do
    case command |> String.trim() |> String.replace_prefix("mv ", "") |> String.split() do
      [source, dest] ->
        rewritten_source = rewrite_path(source, source_cwd, target_dir)
        rewritten_dest = rewrite_path(dest, source_cwd, target_dir)
        File.mkdir_p!(Path.dirname(rewritten_dest))
        File.rename!(rewritten_source, rewritten_dest)

      _ ->
        :skip
    end
  end

  # -- Path rewriting

  defp rewrite_path(path, source_cwd, target_dir) do
    String.replace(path, source_cwd, target_dir)
  end

  defp resolve_cwd(transcript, opts) do
    case Keyword.get(opts, :source_cwd) do
      nil -> extract_cwd(transcript)
      cwd -> {:ok, cwd}
    end
  end

  defp extract_cwd(transcript) do
    case Enum.find(transcript.entries, &(&1.cwd != nil)) do
      nil -> {:error, :no_cwd_found}
      entry -> {:ok, entry.cwd}
    end
  end
end
