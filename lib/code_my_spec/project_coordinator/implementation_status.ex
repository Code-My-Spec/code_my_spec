defmodule CodeMySpec.ProjectCoordinator.ImplementationStatus do
  @moduledoc """
  Manages the implementation status file as a dispatch registry.

  Tracks dispatched tasks with their expected files and prompt paths so that
  returning subagents can be matched to the work they were assigned. Used by
  StartImplementation, Dispatch, and Validation.

  ## Format

      %{
        "dispatched_tasks" => [
          %{
            "requirement" => "component_implementation",
            "component_id" => "aaaa-1111",
            "component_module" => "MyApp.Accounts",
            "prompt_path" => ".code_my_spec/tasks/develop/MyApp.Accounts_component_code.md",
            "expected_files" => ["lib/my_app/accounts.ex", "test/my_app/accounts_test.exs"],
            "task_key" => "develop_context",
            "dispatched_at" => "2026-03-07T12:00:00Z"
          }
        ],
        "updated_at" => "2026-03-07T12:00:05Z"
      }
  """

  require Logger

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Environments
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Transcripts.ClaudeCode.Entry
  alias CodeMySpec.Transcripts.ClaudeCode.FileExtractor
  alias CodeMySpec.Transcripts.ClaudeCode.Parser, as: TranscriptParser
  alias CodeMySpec.Utils

  @status_path CodeMySpec.Paths.implementation_status_path()

  # ============================================================================
  # Read
  # ============================================================================

  @doc "Read the status file. Returns `{:ok, map}` or `{:error, :not_found}`."
  @spec read(term()) :: {:ok, map()} | {:error, :not_found}
  def read(env) do
    case Environments.read_file(env, @status_path) do
      {:ok, ""} -> {:error, :not_found}
      {:ok, content} -> {:ok, Jason.decode!(content)}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc "Read dispatched tasks list. Returns empty list if file doesn't exist."
  @spec dispatched_tasks(term()) :: [map()]
  def dispatched_tasks(env) do
    case read(env) do
      {:ok, data} -> data["dispatched_tasks"] || []
      {:error, :not_found} -> []
    end
  end

  # ============================================================================
  # Write
  # ============================================================================

  @doc """
  Record a dispatched task for a requirement.

  Appends to the dispatched_tasks list. If a task for the same component_id
  and requirement already exists, it is replaced.
  """
  @spec record_task(term(), map()) :: :ok
  def record_task(env, task_entry) do
    existing = dispatched_tasks(env)

    # Replace existing entry for same component + requirement, or append
    filtered =
      Enum.reject(existing, fn t ->
        t["component_id"] == task_entry["component_id"] &&
          t["requirement"] == task_entry["requirement"]
      end)

    tasks = filtered ++ [task_entry]
    write_tasks(env, tasks)
  end

  @doc """
  Build a task entry from a requirement and component.

  `expected_files` is derived from `Utils.component_files/2`, filtered
  by the requirement's artifact type.
  """
  @spec build_task_entry(Requirement.t(), Component.t() | nil, Project.t(), keyword()) :: map()
  def build_task_entry(%Requirement{} = req, component, project, opts \\ []) do
    entry = %{
      "requirement" => req.name,
      "component_id" => req.component_id,
      "story_id" => req.story_id,
      "project_id" => req.project_id,
      "scope" => to_string(req.scope),
      "dispatched_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    entry =
      if prompt_path = Keyword.get(opts, :prompt_path) do
        Map.put(entry, "prompt_path", prompt_path)
      else
        entry
      end

    entry =
      if component do
        files = expected_files_for(req, component, project)

        Map.merge(entry, %{
          "component_module" => component.module_name,
          "expected_files" => files,
          "task_key" => Keyword.get(opts, :task_key)
        })
      else
        entry
      end

    entry
  end

  # ============================================================================
  # Remove / Clear
  # ============================================================================

  @doc "Remove a completed task by component_id and requirement name."
  @spec remove_task(term(), String.t(), String.t()) :: :ok
  def remove_task(env, component_id, requirement) do
    tasks =
      dispatched_tasks(env)
      |> Enum.reject(fn t ->
        t["component_id"] == component_id && t["requirement"] == requirement
      end)

    if tasks == [] do
      clear(env)
    else
      write_tasks(env, tasks)
    end
  end

  @doc "Clear the entire status file."
  @spec clear(term()) :: :ok
  def clear(env) do
    Environments.delete_file(env, @status_path)
    :ok
  end

  # ============================================================================
  # Match — find dispatched task by edited files
  # ============================================================================

  @doc """
  Match edited files against dispatched tasks.

  Returns the task with the most overlap, or nil if no match.
  """
  @spec match_task([String.t()], [map()]) :: map() | nil
  def match_task(edited_files, tasks) when is_list(tasks) do
    edited_set = MapSet.new(edited_files)

    tasks
    |> Enum.map(fn task ->
      expected = task["expected_files"] || []
      expected_set = MapSet.new(expected)
      overlap = MapSet.intersection(edited_set, expected_set) |> MapSet.size()
      {task, overlap}
    end)
    |> Enum.reject(fn {_task, overlap} -> overlap == 0 end)
    |> Enum.sort_by(fn {_task, overlap} -> overlap end, :desc)
    |> case do
      [{task, _} | _] -> task
      [] -> nil
    end
  end

  # ============================================================================
  # Identify — match subagent transcript to dispatched task
  # ============================================================================

  @doc """
  Identify which dispatched task a subagent was working on by examining its transcript.

  Primary match: the subagent's first user message contains a dispatched task's `prompt_path`.
  Fallback: match files the subagent edited against task `expected_files`.

  Returns the matched task map or nil.
  """
  @spec identify_task_from_transcript(term(), String.t()) :: map() | nil
  def identify_task_from_transcript(env, agent_transcript_path) do
    tasks = dispatched_tasks(env)

    if tasks == [] do
      nil
    else
      initial_prompt = extract_initial_prompt(agent_transcript_path)

      if is_nil(initial_prompt) do
        Logger.warning("[ImplementationStatus] No initial prompt in transcript")
        nil
      else
        match_by_prompt_or_files(initial_prompt, tasks, agent_transcript_path)
      end
    end
  end

  defp match_by_prompt_or_files(initial_prompt, tasks, agent_transcript_path) do
    # Primary: does the initial prompt mention any dispatched task's prompt_path?
    prompt_match =
      Enum.find(tasks, fn task ->
        prompt_path = task["prompt_path"]
        prompt_path && String.contains?(initial_prompt, prompt_path)
      end)

    if prompt_match do
      prompt_match
    else
      # Fallback: match files the subagent touched against task expected_files
      Logger.warning(
        "[ImplementationStatus] No prompt_path match, falling back to expected_files matching"
      )

      touched_files = extract_touched_files(agent_transcript_path)
      match_task(touched_files, tasks)
    end
  end

  @doc false
  def extract_initial_prompt(transcript_path) do
    case TranscriptParser.parse(transcript_path) do
      {:ok, transcript} ->
        transcript.entries
        |> Enum.find(&Entry.user?/1)
        |> case do
          nil -> nil
          entry -> extract_text_content(Entry.content(entry))
        end

      {:error, _} ->
        nil
    end
  end

  defp extract_text_content(text) when is_binary(text), do: text

  defp extract_text_content(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(fn
      %{"type" => "text"} -> true
      _ -> false
    end)
    |> Enum.map_join("\n", & &1["text"])
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp extract_text_content(_), do: nil

  defp extract_touched_files(transcript_path) do
    case TranscriptParser.parse(transcript_path) do
      {:ok, transcript} ->
        absolute_paths = FileExtractor.extract_edited_files(transcript)
        cwd = transcript_cwd(transcript)
        relativize_paths(absolute_paths, cwd)

      {:error, _} ->
        []
    end
  end

  defp relativize_paths(paths, nil), do: paths

  defp relativize_paths(paths, cwd) do
    prefix = String.trim_trailing(cwd, "/") <> "/"

    Enum.map(paths, fn path ->
      if String.starts_with?(path, prefix) do
        String.replace_prefix(path, prefix, "")
      else
        path
      end
    end)
  end

  defp transcript_cwd(%{entries: [first | _]}), do: first.cwd
  defp transcript_cwd(_), do: nil

  # ============================================================================
  # Private
  # ============================================================================

  defp write_tasks(env, tasks) do
    data = %{
      "dispatched_tasks" => tasks,
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :ok = Environments.write_file(env, @status_path, Jason.encode!(data))
  end

  @doc false
  def expected_files_for(%Requirement{} = req, %Component{} = component, %Project{} = project) do
    files = Utils.component_files(component, project)

    case req.name do
      # Design requirements → spec file
      name when name in ["spec_file", "spec_valid", "component_design"] ->
        [files.spec_file] |> compact()

      # Implementation → code + test
      name when name in ["implementation_file", "component_implementation", "tests_passing"] ->
        [files.code_file, files.test_file] |> compact()

      # Test file → test only
      name when name in ["test_file", "test_spec_alignment"] ->
        [files.test_file] |> compact()

      # JSON file → json + code
      "json_file" ->
        [files[:json_file], files.code_file] |> compact()

      # Review → review file
      name when name in ["review_file", "review_valid"] ->
        [files[:review_file]] |> compact()

      # Children scope → all files for this component
      _ when req.scope == :children ->
        Map.values(files) |> List.flatten() |> compact()

      # Default → all files
      _ ->
        Map.values(files) |> List.flatten() |> compact()
    end
  end

  defp compact(list), do: Enum.reject(list, &is_nil/1)
end
