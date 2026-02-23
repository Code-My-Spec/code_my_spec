defmodule CodeMySpec.Support.ScenarioHelpers do
  @moduledoc """
  Test helpers for transcript-based scenario testing.

  Provides utilities for replaying recorded transcripts against test projects
  and snapshot-based assertion testing for prompt regression detection.
  """

  alias CodeMySpec.Transcripts.Replayer

  @scenarios_dir "test/fixtures/scenarios"
  @snapshots_dir "test/fixtures/snapshots"

  @doc """
  Replays a single phase transcript onto the target project directory.

  Looks up the transcript fixture by phase name in `test/fixtures/scenarios/`.

  ## Parameters

    - `project_dir` - Target directory to apply file changes to
    - `phase_name` - Name of the phase (e.g., "01_project_setup")
    - `opts` - Options passed through to `Replayer.replay/3`

  ## Examples

      replay_phase(project_dir, "01_project_setup")
      replay_phase(project_dir, "02_architecture_design", source_cwd: "/original/path")
  """
  def replay_phase(project_dir, phase_name, opts \\ []) do
    transcript_path = scenario_fixture_path(phase_name)

    unless File.exists?(transcript_path) do
      raise "Scenario fixture not found: #{transcript_path}"
    end

    case Replayer.replay(transcript_path, project_dir, opts) do
      :ok -> :ok
      {:error, reason} -> raise "Failed to replay phase #{phase_name}: #{inspect(reason)}"
    end
  end

  @doc """
  Replays multiple phases in order onto the target project directory.

  Each phase is applied sequentially, building on the previous phase's changes.

  ## Parameters

    - `project_dir` - Target directory to apply file changes to
    - `phase_names` - List of phase names to replay in order
    - `opts` - Options passed through to each replay

  ## Examples

      replay_phases(project_dir, ["01_project_setup", "02_architecture_design"])
  """
  def replay_phases(project_dir, phase_names, opts \\ []) do
    Enum.each(phase_names, &replay_phase(project_dir, &1, opts))
  end

  @doc """
  Asserts that content matches a saved snapshot.

  Compares `content` against the snapshot file at `test/fixtures/snapshots/{name}.txt`.
  Fails with a diff if the content doesn't match. If the snapshot doesn't exist,
  creates it (first run).

  Set `UPDATE_SNAPSHOTS=true` to overwrite existing snapshots.

  ## Parameters

    - `name` - Snapshot name (used as filename without extension)
    - `content` - String content to compare against the snapshot

  ## Examples

      assert_snapshot("project_setup_prompt", prompt_output)
  """
  def assert_snapshot(name, content) do
    path = snapshot_path(name)
    normalized = normalize_snapshot(content)

    if System.get_env("UPDATE_SNAPSHOTS") == "true" || !File.exists?(path) do
      save_snapshot(name, normalized)
    else
      saved = File.read!(path)

      if saved != normalized do
        ExUnit.Assertions.flunk("""
        Snapshot mismatch for "#{name}".

        Run with UPDATE_SNAPSHOTS=true to update.

        Diff:
        #{snapshot_diff(saved, normalized)}
        """)
      end
    end
  end

  @doc """
  Saves content as a snapshot file.

  Writes to `test/fixtures/snapshots/{name}.txt`, creating directories as needed.
  """
  def save_snapshot(name, content) do
    path = snapshot_path(name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  # Normalization — strip run-specific paths so snapshots are deterministic

  defp normalize_snapshot(content) do
    # Replace tmp dir paths like /var/folders/.../scenario_123/... with <TMP>/...
    content
    |> String.replace(~r|/var/folders/[^\s]+/scenario_\d+/|, "<TMP>/")
    |> String.replace(~r|/tmp/scenario_\d+/|, "<TMP>/")
  end

  # Private helpers

  defp scenario_fixture_path(phase_name) do
    Path.join(@scenarios_dir, "#{phase_name}.jsonl")
  end

  defp snapshot_path(name) do
    Path.join(@snapshots_dir, "#{name}.txt")
  end

  defp snapshot_diff(expected, actual) do
    expected_lines = String.split(expected, "\n")
    actual_lines = String.split(actual, "\n")

    List.myers_difference(expected_lines, actual_lines)
    |> Enum.flat_map(fn
      {:eq, lines} -> Enum.map(lines, &"  #{&1}")
      {:del, lines} -> Enum.map(lines, &"- #{&1}")
      {:ins, lines} -> Enum.map(lines, &"+ #{&1}")
    end)
    |> Enum.join("\n")
  end
end
