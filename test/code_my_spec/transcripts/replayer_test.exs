defmodule CodeMySpec.Transcripts.ReplayerTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Transcripts.Replayer

  import CodeMySpec.TranscriptFixtures

  @source_cwd "/Users/dev/project"

  describe "replay/3 with Write operations" do
    @tag :tmp_dir
    test "creates a new file from a Write tool call", %{tmp_dir: tmp_dir} do
      transcript_path = create_write_transcript(tmp_dir)

      assert :ok = Replayer.replay(transcript_path, tmp_dir, source_cwd: @source_cwd)

      written_path = Path.join(tmp_dir, "src/new_file.ex")
      assert File.exists?(written_path)
      assert File.read!(written_path) == "defmodule Foo do\nend"
    end

    @tag :tmp_dir
    test "creates parent directories for Write operations", %{tmp_dir: tmp_dir} do
      transcript_path = create_write_deep_path_transcript(tmp_dir)

      assert :ok = Replayer.replay(transcript_path, tmp_dir, source_cwd: @source_cwd)

      written_path = Path.join(tmp_dir, "lib/deep/nested/module.ex")
      assert File.exists?(written_path)
    end

    @tag :tmp_dir
    test "overwrites existing file with Write", %{tmp_dir: tmp_dir} do
      target_file = Path.join(tmp_dir, "src/existing.ex")
      File.mkdir_p!(Path.dirname(target_file))
      File.write!(target_file, "old content")

      transcript_path = create_write_overwrite_transcript(tmp_dir)

      assert :ok = Replayer.replay(transcript_path, tmp_dir, source_cwd: @source_cwd)
      assert File.read!(target_file) == "new content"
    end
  end

  describe "replay/3 with Edit operations" do
    @tag :tmp_dir
    test "replaces old_string with new_string in existing file", %{tmp_dir: tmp_dir} do
      target_file = Path.join(tmp_dir, "src/main.ex")
      File.mkdir_p!(Path.dirname(target_file))
      File.write!(target_file, "defmodule Main do\n  def foo, do: :old\nend\n")

      transcript_path = create_edit_transcript(tmp_dir)

      assert :ok = Replayer.replay(transcript_path, tmp_dir, source_cwd: @source_cwd)
      assert File.read!(target_file) == "defmodule Main do\n  def foo, do: :new\nend\n"
    end

    @tag :tmp_dir
    test "applies only the first occurrence of old_string", %{tmp_dir: tmp_dir} do
      target_file = Path.join(tmp_dir, "src/main.ex")
      File.mkdir_p!(Path.dirname(target_file))
      File.write!(target_file, "foo foo foo")

      transcript_path = create_edit_first_occurrence_transcript(tmp_dir)

      assert :ok = Replayer.replay(transcript_path, tmp_dir, source_cwd: @source_cwd)
      assert File.read!(target_file) == "bar foo foo"
    end
  end

  describe "replay/3 with mixed operations" do
    @tag :tmp_dir
    test "applies Write then Edit in chronological order", %{tmp_dir: tmp_dir} do
      transcript_path = create_write_then_edit_transcript(tmp_dir)

      assert :ok = Replayer.replay(transcript_path, tmp_dir, source_cwd: @source_cwd)

      file_path = Path.join(tmp_dir, "src/module.ex")
      assert File.read!(file_path) == "defmodule Module do\n  def hello, do: :world\nend\n"
    end
  end

  describe "replay/3 with Bash mkdir operations" do
    @tag :tmp_dir
    test "creates directories from mkdir -p", %{tmp_dir: tmp_dir} do
      transcript_path = create_mkdir_transcript(tmp_dir)

      assert :ok = Replayer.replay(transcript_path, tmp_dir, source_cwd: @source_cwd)

      assert File.dir?(Path.join(tmp_dir, ".code_my_spec/rules"))
      assert File.dir?(Path.join(tmp_dir, ".code_my_spec/spec/my_app"))
    end

    @tag :tmp_dir
    test "creates multiple directories from single mkdir -p", %{tmp_dir: tmp_dir} do
      transcript_path = create_mkdir_multi_transcript(tmp_dir)

      assert :ok = Replayer.replay(transcript_path, tmp_dir, source_cwd: @source_cwd)

      assert File.dir?(Path.join(tmp_dir, "a/b"))
      assert File.dir?(Path.join(tmp_dir, "c/d"))
      assert File.dir?(Path.join(tmp_dir, "e/f"))
    end
  end

  describe "replay/3 with Bash mv operations" do
    @tag :tmp_dir
    test "renames a file via mv", %{tmp_dir: tmp_dir} do
      # Create the source file first
      source = Path.join(tmp_dir, "src/old_name.ex")
      File.mkdir_p!(Path.dirname(source))
      File.write!(source, "content")

      transcript_path = create_mv_transcript(tmp_dir)

      assert :ok = Replayer.replay(transcript_path, tmp_dir, source_cwd: @source_cwd)

      refute File.exists?(Path.join(tmp_dir, "src/old_name.ex"))
      assert File.read!(Path.join(tmp_dir, "src/new_name.ex")) == "content"
    end
  end

  describe "replay/3 skips non-replayable Bash" do
    @tag :tmp_dir
    test "skips mix compile and other commands", %{tmp_dir: tmp_dir} do
      transcript_path = create_non_replayable_bash_transcript(tmp_dir)

      # Should not raise or error
      assert :ok = Replayer.replay(transcript_path, tmp_dir, source_cwd: @source_cwd)
    end
  end

  describe "replay/3 path rewriting" do
    @tag :tmp_dir
    test "rewrites recorded absolute paths to target directory", %{tmp_dir: tmp_dir} do
      transcript_path = create_write_transcript(tmp_dir)

      assert :ok = Replayer.replay(transcript_path, tmp_dir, source_cwd: @source_cwd)

      # File should be at target_dir/src/new_file.ex, not at the original absolute path
      assert File.exists?(Path.join(tmp_dir, "src/new_file.ex"))
      refute File.exists?("/Users/dev/project/src/new_file.ex")
    end

    @tag :tmp_dir
    test "extracts cwd from transcript entries", %{tmp_dir: tmp_dir} do
      # Don't pass source_cwd, let it extract from the transcript entry cwd field
      transcript_path = create_write_transcript_with_cwd(tmp_dir, "/original/project")

      assert :ok = Replayer.replay(transcript_path, tmp_dir)

      assert File.exists?(Path.join(tmp_dir, "src/new_file.ex"))
    end

    @tag :tmp_dir
    test "source_cwd option overrides transcript cwd", %{tmp_dir: tmp_dir} do
      transcript_path = create_write_transcript_with_cwd(tmp_dir, "/original/project")

      # Override with a different source_cwd that matches the paths in the transcript
      assert :ok = Replayer.replay(transcript_path, tmp_dir, source_cwd: "/original/project")

      assert File.exists?(Path.join(tmp_dir, "src/new_file.ex"))
    end
  end

  describe "replay/3 error handling" do
    @tag :tmp_dir
    test "returns error when transcript file not found", %{tmp_dir: tmp_dir} do
      assert {:error, :file_not_found} =
               Replayer.replay("/nonexistent.jsonl", tmp_dir, source_cwd: @source_cwd)
    end

    @tag :tmp_dir
    test "returns error when no cwd found and none provided", %{tmp_dir: tmp_dir} do
      transcript_path = create_transcript_without_cwd(tmp_dir)

      assert {:error, :no_cwd_found} = Replayer.replay(transcript_path, tmp_dir)
    end
  end

  describe "replay_transcript/3" do
    @tag :tmp_dir
    test "replays from an already-parsed transcript struct", %{tmp_dir: tmp_dir} do
      target_file = Path.join(tmp_dir, "src/main.ex")
      File.mkdir_p!(Path.dirname(target_file))
      File.write!(target_file, "old content")

      transcript = build_transcript_with_write(@source_cwd)

      assert :ok = Replayer.replay_transcript(transcript, tmp_dir, source_cwd: @source_cwd)
      assert File.read!(Path.join(tmp_dir, "src/main.ex")) == "new content"
    end
  end

  # ============================================================================
  # Transcript builders for tests
  # ============================================================================

  defp create_write_transcript(tmp_dir) do
    entries = [
      user_entry_json(%{"cwd" => @source_cwd}),
      assistant_entry_with_tools([
        write_tool_json(%{
          "input" => %{
            "file_path" => "#{@source_cwd}/src/new_file.ex",
            "content" => "defmodule Foo do\nend"
          }
        })
      ])
    ]

    write_jsonl_file(tmp_dir, "write_transcript.jsonl", to_jsonl_content(entries))
  end

  defp create_write_deep_path_transcript(tmp_dir) do
    entries = [
      user_entry_json(%{"cwd" => @source_cwd}),
      assistant_entry_with_tools([
        write_tool_json(%{
          "input" => %{
            "file_path" => "#{@source_cwd}/lib/deep/nested/module.ex",
            "content" => "defmodule Deep.Nested.Module do\nend"
          }
        })
      ])
    ]

    write_jsonl_file(tmp_dir, "deep_write_transcript.jsonl", to_jsonl_content(entries))
  end

  defp create_write_overwrite_transcript(tmp_dir) do
    entries = [
      user_entry_json(%{"cwd" => @source_cwd}),
      assistant_entry_with_tools([
        write_tool_json(%{
          "input" => %{
            "file_path" => "#{@source_cwd}/src/existing.ex",
            "content" => "new content"
          }
        })
      ])
    ]

    write_jsonl_file(tmp_dir, "overwrite_transcript.jsonl", to_jsonl_content(entries))
  end

  defp create_edit_transcript(tmp_dir) do
    entries = [
      user_entry_json(%{"cwd" => @source_cwd}),
      assistant_entry_with_tools([
        edit_tool_json(%{
          "input" => %{
            "file_path" => "#{@source_cwd}/src/main.ex",
            "old_string" => "def foo, do: :old",
            "new_string" => "def foo, do: :new"
          }
        })
      ])
    ]

    write_jsonl_file(tmp_dir, "edit_transcript.jsonl", to_jsonl_content(entries))
  end

  defp create_edit_first_occurrence_transcript(tmp_dir) do
    entries = [
      user_entry_json(%{"cwd" => @source_cwd}),
      assistant_entry_with_tools([
        edit_tool_json(%{
          "input" => %{
            "file_path" => "#{@source_cwd}/src/main.ex",
            "old_string" => "foo",
            "new_string" => "bar"
          }
        })
      ])
    ]

    write_jsonl_file(tmp_dir, "edit_first_transcript.jsonl", to_jsonl_content(entries))
  end

  defp create_write_then_edit_transcript(tmp_dir) do
    entries = [
      user_entry_json(%{"cwd" => @source_cwd}),
      assistant_entry_with_tools(
        [
          write_tool_json(%{
            "id" => "write_1",
            "input" => %{
              "file_path" => "#{@source_cwd}/src/module.ex",
              "content" => "defmodule Module do\n  def hello, do: :placeholder\nend\n"
            }
          })
        ],
        %{"uuid" => "assistant-1"}
      ),
      user_entry_json(%{"uuid" => "user-2", "cwd" => @source_cwd}),
      assistant_entry_with_tools(
        [
          edit_tool_json(%{
            "id" => "edit_1",
            "input" => %{
              "file_path" => "#{@source_cwd}/src/module.ex",
              "old_string" => "def hello, do: :placeholder",
              "new_string" => "def hello, do: :world"
            }
          })
        ],
        %{"uuid" => "assistant-2"}
      )
    ]

    write_jsonl_file(tmp_dir, "write_edit_transcript.jsonl", to_jsonl_content(entries))
  end

  defp create_write_transcript_with_cwd(tmp_dir, cwd) do
    entries = [
      user_entry_json(%{"cwd" => cwd}),
      assistant_entry_with_tools([
        write_tool_json(%{
          "input" => %{
            "file_path" => "#{cwd}/src/new_file.ex",
            "content" => "defmodule Foo do\nend"
          }
        })
      ])
    ]

    write_jsonl_file(tmp_dir, "cwd_transcript.jsonl", to_jsonl_content(entries))
  end

  defp create_transcript_without_cwd(tmp_dir) do
    entries = [
      user_entry_json(%{"cwd" => nil}),
      assistant_entry_json(%{"cwd" => nil})
    ]

    write_jsonl_file(tmp_dir, "no_cwd_transcript.jsonl", to_jsonl_content(entries))
  end

  defp create_mkdir_transcript(tmp_dir) do
    entries = [
      user_entry_json(%{"cwd" => @source_cwd}),
      assistant_entry_with_tools([
        bash_tool_json(%{
          "input" => %{
            "command" => "mkdir -p #{@source_cwd}/.code_my_spec/rules #{@source_cwd}/.code_my_spec/spec/my_app"
          }
        })
      ])
    ]

    write_jsonl_file(tmp_dir, "mkdir_transcript.jsonl", to_jsonl_content(entries))
  end

  defp create_mkdir_multi_transcript(tmp_dir) do
    entries = [
      user_entry_json(%{"cwd" => @source_cwd}),
      assistant_entry_with_tools([
        bash_tool_json(%{
          "input" => %{
            "command" => "mkdir -p #{@source_cwd}/a/b #{@source_cwd}/c/d #{@source_cwd}/e/f"
          }
        })
      ])
    ]

    write_jsonl_file(tmp_dir, "mkdir_multi_transcript.jsonl", to_jsonl_content(entries))
  end

  defp create_mv_transcript(tmp_dir) do
    entries = [
      user_entry_json(%{"cwd" => @source_cwd}),
      assistant_entry_with_tools([
        bash_tool_json(%{
          "input" => %{
            "command" => "mv #{@source_cwd}/src/old_name.ex #{@source_cwd}/src/new_name.ex"
          }
        })
      ])
    ]

    write_jsonl_file(tmp_dir, "mv_transcript.jsonl", to_jsonl_content(entries))
  end

  defp create_non_replayable_bash_transcript(tmp_dir) do
    entries = [
      user_entry_json(%{"cwd" => @source_cwd}),
      assistant_entry_with_tools([
        bash_tool_json(%{"input" => %{"command" => "mix deps.get"}}),
        bash_tool_json(%{
          "id" => "toolu_bash_013",
          "input" => %{"command" => "MIX_ENV=test mix compile"}
        }),
        bash_tool_json(%{
          "id" => "toolu_bash_014",
          "input" => %{"command" => "elixir --version"}
        })
      ])
    ]

    write_jsonl_file(tmp_dir, "non_replayable_transcript.jsonl", to_jsonl_content(entries))
  end

  defp build_transcript_with_write(source_cwd) do
    entries = [
      build_entry(user_entry_json(%{"cwd" => source_cwd})),
      build_entry(
        assistant_entry_with_tools([
          write_tool_json(%{
            "input" => %{
              "file_path" => "#{source_cwd}/src/main.ex",
              "content" => "new content"
            }
          })
        ])
      )
    ]

    build_transcript(entries)
  end
end
