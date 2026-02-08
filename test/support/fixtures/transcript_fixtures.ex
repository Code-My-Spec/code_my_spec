defmodule CodeMySpec.TranscriptFixtures do
  @moduledoc """
  Test fixtures for Claude Code transcript parsing.

  Provides reusable JSON data and JSONL file helpers for testing
  Entry, Transcript, and Parser modules.
  """

  # ============================================================================
  # JSON Entry Fixtures
  # ============================================================================

  @doc """
  Returns a valid user message JSON map as Claude Code stores it.
  """
  def user_entry_json(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "user",
        "uuid" => "user-uuid-123",
        "parentUuid" => nil,
        "timestamp" => "2024-01-15T10:30:00Z",
        "sessionId" => "session-789",
        "agentId" => "agent-001",
        "cwd" => "/Users/dev/project",
        "version" => "1.0.0",
        "gitBranch" => "main",
        "isSidechain" => false,
        "userType" => "external",
        "message" => %{
          "role" => "user",
          "content" => "Hello, can you help me with this code?"
        }
      },
      overrides
    )
  end

  @doc """
  Returns a valid assistant message JSON map with text content.
  """
  def assistant_entry_json(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "assistant",
        "uuid" => "assistant-uuid-456",
        "parentUuid" => "user-uuid-123",
        "timestamp" => "2024-01-15T10:30:05Z",
        "sessionId" => "session-789",
        "agentId" => "agent-001",
        "cwd" => "/Users/dev/project",
        "version" => "1.0.0",
        "gitBranch" => "main",
        "isSidechain" => false,
        "requestId" => "req_abc123",
        "message" => %{
          "role" => "assistant",
          "content" => [
            %{"type" => "text", "text" => "I'd be happy to help!"}
          ]
        }
      },
      overrides
    )
  end

  @doc """
  Returns an assistant entry JSON with tool_use blocks.
  """
  def assistant_with_tool_use_json(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "assistant",
        "uuid" => "tool-use-uuid",
        "parentUuid" => "user-uuid-123",
        "timestamp" => "2024-01-15T10:30:10Z",
        "sessionId" => "session-789",
        "message" => %{
          "role" => "assistant",
          "content" => [
            %{"type" => "text", "text" => "Let me read that file."},
            %{
              "type" => "tool_use",
              "id" => "tool_1",
              "name" => "Read",
              "input" => %{"file_path" => "/src/main.ex"}
            }
          ]
        }
      },
      overrides
    )
  end

  @doc """
  Returns a user entry JSON with tool_result blocks.
  """
  def user_with_tool_result_json(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "user",
        "uuid" => "tool-result-uuid",
        "parentUuid" => "tool-use-uuid",
        "timestamp" => "2024-01-15T10:30:15Z",
        "sessionId" => "session-789",
        "message" => %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => "tool_1",
              "content" => "defmodule Main do\nend"
            }
          ]
        }
      },
      overrides
    )
  end

  # ============================================================================
  # JSONL Content Helpers
  # ============================================================================

  @doc """
  Converts a JSON map to a JSONL line (encoded JSON string).
  """
  def to_jsonl_line(json_map) do
    Jason.encode!(json_map)
  end

  @doc """
  Creates JSONL content from a list of JSON maps.
  Each map becomes a line in the output.
  """
  def to_jsonl_content(json_maps) when is_list(json_maps) do
    Enum.map_join(json_maps, "\n", &to_jsonl_line/1)
  end

  @doc """
  Creates a valid single-entry JSONL content string.
  """
  def single_entry_jsonl do
    to_jsonl_content([user_entry_json()])
  end

  @doc """
  Creates a valid multi-entry JSONL content string (user + assistant).
  """
  def multi_entry_jsonl do
    to_jsonl_content([user_entry_json(), assistant_entry_json()])
  end

  @doc """
  Creates a conversation with tool use and result.
  """
  def tool_use_conversation_jsonl do
    to_jsonl_content([
      user_entry_json(),
      assistant_with_tool_use_json(),
      user_with_tool_result_json()
    ])
  end

  # ============================================================================
  # Tmp File Helpers
  # ============================================================================

  @doc """
  Writes JSONL content to a file in the given tmp directory.
  Returns the full file path.
  """
  def write_jsonl_file(tmp_dir, filename, content) do
    path = Path.join(tmp_dir, filename)
    File.write!(path, content)
    path
  end

  @doc """
  Creates a valid transcript file with user and assistant entries.
  Returns the file path.
  """
  def create_valid_transcript(tmp_dir, filename \\ "transcript.jsonl") do
    write_jsonl_file(tmp_dir, filename, multi_entry_jsonl())
  end

  @doc """
  Creates an empty transcript file.
  Returns the file path.
  """
  def create_empty_transcript(tmp_dir, filename \\ "empty.jsonl") do
    write_jsonl_file(tmp_dir, filename, "")
  end

  @doc """
  Creates a transcript file with malformed JSON on a specific line.
  """
  def create_malformed_transcript(tmp_dir, filename \\ "malformed.jsonl") do
    content = """
    #{to_jsonl_line(user_entry_json())}
    {invalid json here
    #{to_jsonl_line(assistant_entry_json())}
    """

    write_jsonl_file(tmp_dir, filename, String.trim(content))
  end

  # ============================================================================
  # Edge Case Fixtures
  # ============================================================================

  @doc """
  Creates JSONL with empty lines between entries.
  """
  def jsonl_with_empty_lines do
    line1 = to_jsonl_line(user_entry_json())
    line2 = to_jsonl_line(assistant_entry_json())
    "#{line1}\n\n\n#{line2}\n"
  end

  @doc """
  Creates JSONL with trailing newline.
  """
  def jsonl_with_trailing_newline do
    multi_entry_jsonl() <> "\n"
  end

  @doc """
  Creates JSONL with whitespace-only lines.
  """
  def jsonl_with_whitespace_lines do
    line1 = to_jsonl_line(user_entry_json())
    line2 = to_jsonl_line(assistant_entry_json())
    "#{line1}\n   \n\t\n#{line2}"
  end

  @doc """
  Creates JSONL with nested JSON structures.
  """
  def jsonl_with_nested_structures do
    entry =
      user_entry_json(%{
        "message" => %{
          "role" => "user",
          "content" => "test",
          "metadata" => %{
            "nested" => %{
              "deeply" => %{
                "value" => [1, 2, 3]
              }
            }
          }
        }
      })

    to_jsonl_content([entry])
  end

  @doc """
  Creates JSONL with unicode characters.
  """
  def jsonl_with_unicode do
    entry =
      user_entry_json(%{
        "message" => %{
          "role" => "user",
          "content" => "Hello 你好 مرحبا 🎉 émoji café"
        }
      })

    to_jsonl_content([entry])
  end

  @doc """
  Creates JSONL with special JSON characters in strings.
  """
  def jsonl_with_special_chars do
    entry =
      user_entry_json(%{
        "message" => %{
          "role" => "user",
          "content" => "Quote: \"test\" and backslash: \\ and newline: \n tab: \t"
        }
      })

    to_jsonl_content([entry])
  end

  @doc """
  Creates JSONL with a very long line.
  """
  def jsonl_with_long_line do
    long_content = String.duplicate("x", 10_000)

    entry =
      user_entry_json(%{
        "message" => %{
          "role" => "user",
          "content" => long_content
        }
      })

    to_jsonl_content([entry])
  end

  @doc """
  Creates JSONL with CRLF line endings (Windows style).
  """
  def jsonl_with_crlf do
    line1 = to_jsonl_line(user_entry_json())
    line2 = to_jsonl_line(assistant_entry_json())
    "#{line1}\r\n#{line2}\r\n"
  end

  # ============================================================================
  # Tool Call Fixtures
  # ============================================================================

  @doc """
  Returns JSON for an Edit tool_use block.
  """
  def edit_tool_json(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "toolu_edit_123",
        "name" => "Edit",
        "input" => %{"file_path" => "/src/main.ex", "old_string" => "foo", "new_string" => "bar"}
      },
      overrides
    )
  end

  @doc """
  Returns JSON for a Write tool_use block.
  """
  def write_tool_json(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "toolu_write_456",
        "name" => "Write",
        "input" => %{"file_path" => "/src/new_file.ex", "content" => "defmodule Foo do\nend"}
      },
      overrides
    )
  end

  @doc """
  Returns JSON for a Read tool_use block.
  """
  def read_tool_json(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "toolu_read_789",
        "name" => "Read",
        "input" => %{"file_path" => "/src/main.ex"}
      },
      overrides
    )
  end

  @doc """
  Returns JSON for a Bash tool_use block.
  """
  def bash_tool_json(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "toolu_bash_012",
        "name" => "Bash",
        "input" => %{"command" => "mix test"}
      },
      overrides
    )
  end

  @doc """
  Returns JSON for a Glob tool_use block.
  """
  def glob_tool_json(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "toolu_glob_345",
        "name" => "Glob",
        "input" => %{"pattern" => "**/*.ex"}
      },
      overrides
    )
  end

  @doc """
  Returns JSON for a Grep tool_use block.
  """
  def grep_tool_json(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "toolu_grep_678",
        "name" => "Grep",
        "input" => %{"pattern" => "def "}
      },
      overrides
    )
  end

  # ============================================================================
  # Transcript Building Helpers
  # ============================================================================

  @doc """
  Creates a Transcript struct with the given entries.
  Entries should be Entry structs.
  """
  def build_transcript(entries, path \\ "/test/transcript.jsonl") do
    alias CodeMySpec.Transcripts.ClaudeCode.Transcript
    Transcript.new(path, entries)
  end

  @doc """
  Creates an Entry struct from JSON.
  """
  def build_entry(json) do
    alias CodeMySpec.Transcripts.ClaudeCode.Entry
    Entry.new(json)
  end

  @doc """
  Creates an assistant entry with the specified tool_use blocks.
  tool_blocks should be a list of tool JSON maps (from edit_tool_json, etc.)
  """
  def assistant_entry_with_tools(tool_blocks, overrides \\ %{}) do
    content_blocks =
      Enum.map(tool_blocks, fn tool ->
        Map.put(tool, "type", "tool_use")
      end)

    assistant_entry_json(
      Map.merge(
        %{
          "message" => %{
            "role" => "assistant",
            "content" => content_blocks
          }
        },
        overrides
      )
    )
  end

  @doc """
  Creates an assistant entry with mixed text and tool_use content.
  """
  def assistant_entry_with_text_and_tools(text, tool_blocks, overrides \\ %{}) do
    tool_content =
      Enum.map(tool_blocks, fn tool ->
        Map.put(tool, "type", "tool_use")
      end)

    content_blocks = [%{"type" => "text", "text" => text} | tool_content]

    assistant_entry_json(
      Map.merge(
        %{
          "message" => %{
            "role" => "assistant",
            "content" => content_blocks
          }
        },
        overrides
      )
    )
  end

  @doc """
  Creates an empty transcript (no entries).
  """
  def empty_transcript do
    build_transcript([])
  end

  @doc """
  Creates a transcript with only user messages (no tool calls).
  """
  def transcript_with_user_only do
    entries = [
      build_entry(user_entry_json()),
      build_entry(user_entry_json(%{"uuid" => "user-2"}))
    ]

    build_transcript(entries)
  end

  @doc """
  Creates a transcript with assistant text responses only (no tool calls).
  """
  def transcript_with_text_only do
    entries = [
      build_entry(user_entry_json()),
      build_entry(assistant_entry_json())
    ]

    build_transcript(entries)
  end

  @doc """
  Creates a transcript with a single Edit tool call.
  """
  def transcript_with_single_edit do
    entries = [
      build_entry(user_entry_json()),
      build_entry(assistant_entry_with_tools([edit_tool_json()]))
    ]

    build_transcript(entries)
  end

  @doc """
  Creates a transcript with a single Write tool call.
  """
  def transcript_with_single_write do
    entries = [
      build_entry(user_entry_json()),
      build_entry(assistant_entry_with_tools([write_tool_json()]))
    ]

    build_transcript(entries)
  end

  @doc """
  Creates a transcript with both Edit and Write tool calls.
  """
  def transcript_with_edit_and_write do
    entries = [
      build_entry(user_entry_json()),
      build_entry(
        assistant_entry_with_tools([
          edit_tool_json(%{"input" => %{"file_path" => "/src/foo.ex"}}),
          write_tool_json(%{"input" => %{"file_path" => "/src/bar.ex", "content" => "content"}})
        ])
      )
    ]

    build_transcript(entries)
  end

  @doc """
  Creates a transcript with only non-file-modifying tool calls (Read, Bash, Glob).
  """
  def transcript_with_read_only_tools do
    entries = [
      build_entry(user_entry_json()),
      build_entry(
        assistant_entry_with_tools([
          read_tool_json(),
          bash_tool_json(),
          glob_tool_json()
        ])
      )
    ]

    build_transcript(entries)
  end

  @doc """
  Creates a transcript with multiple edits to the same file.
  """
  def transcript_with_duplicate_edits do
    entries = [
      build_entry(user_entry_json()),
      build_entry(
        assistant_entry_with_tools([
          edit_tool_json(%{
            "id" => "edit_1",
            "input" => %{"file_path" => "/src/main.ex", "old_string" => "a", "new_string" => "b"}
          }),
          edit_tool_json(%{
            "id" => "edit_2",
            "input" => %{"file_path" => "/src/main.ex", "old_string" => "c", "new_string" => "d"}
          })
        ])
      )
    ]

    build_transcript(entries)
  end

  @doc """
  Creates a transcript with multiple writes to the same file.
  """
  def transcript_with_duplicate_writes do
    entries = [
      build_entry(user_entry_json()),
      build_entry(
        assistant_entry_with_tools([
          write_tool_json(%{
            "id" => "write_1",
            "input" => %{"file_path" => "/src/new.ex", "content" => "v1"}
          })
        ])
      ),
      build_entry(user_entry_json(%{"uuid" => "user-2"})),
      build_entry(
        assistant_entry_with_tools([
          write_tool_json(%{
            "id" => "write_2",
            "input" => %{"file_path" => "/src/new.ex", "content" => "v2"}
          })
        ], %{"uuid" => "assistant-2"})
      )
    ]

    build_transcript(entries)
  end

  @doc """
  Creates a transcript with a tool call missing file_path parameter.
  """
  def transcript_with_malformed_tool_call do
    entries = [
      build_entry(user_entry_json()),
      build_entry(
        assistant_entry_with_tools([
          %{"id" => "edit_bad", "name" => "Edit", "input" => %{"old_string" => "a", "new_string" => "b"}},
          edit_tool_json(%{"id" => "edit_good"})
        ])
      )
    ]

    build_transcript(entries)
  end

  @doc """
  Creates a transcript with tool calls in chronological order across multiple entries.
  Returns {transcript, expected_file_order} for order verification.
  """
  def transcript_with_chronological_edits do
    entries = [
      build_entry(user_entry_json()),
      build_entry(
        assistant_entry_with_tools(
          [edit_tool_json(%{"id" => "edit_1", "input" => %{"file_path" => "/first.ex"}})],
          %{"uuid" => "assistant-1", "timestamp" => "2024-01-15T10:30:00Z"}
        )
      ),
      build_entry(user_entry_json(%{"uuid" => "user-2"})),
      build_entry(
        assistant_entry_with_tools(
          [edit_tool_json(%{"id" => "edit_2", "input" => %{"file_path" => "/second.ex"}})],
          %{"uuid" => "assistant-2", "timestamp" => "2024-01-15T10:31:00Z"}
        )
      ),
      build_entry(user_entry_json(%{"uuid" => "user-3"})),
      build_entry(
        assistant_entry_with_tools(
          [edit_tool_json(%{"id" => "edit_3", "input" => %{"file_path" => "/third.ex"}})],
          %{"uuid" => "assistant-3", "timestamp" => "2024-01-15T10:32:00Z"}
        )
      )
    ]

    {build_transcript(entries), ["/first.ex", "/second.ex", "/third.ex"]}
  end

  @doc """
  Creates a transcript with multiple tool calls in a single entry.
  """
  def transcript_with_multiple_tools_single_entry do
    entries = [
      build_entry(user_entry_json()),
      build_entry(
        assistant_entry_with_tools([
          read_tool_json(%{"id" => "read_1"}),
          edit_tool_json(%{"id" => "edit_1"}),
          bash_tool_json(%{"id" => "bash_1"}),
          write_tool_json(%{"id" => "write_1"})
        ])
      )
    ]

    build_transcript(entries)
  end

  @doc """
  Creates a transcript with tool calls spread across multiple entries.
  """
  def transcript_with_tools_across_entries do
    entries = [
      build_entry(user_entry_json()),
      build_entry(
        assistant_entry_with_tools(
          [read_tool_json(%{"id" => "read_1"})],
          %{"uuid" => "assistant-1"}
        )
      ),
      build_entry(user_entry_json(%{"uuid" => "user-2"})),
      build_entry(
        assistant_entry_with_tools(
          [edit_tool_json(%{"id" => "edit_1"})],
          %{"uuid" => "assistant-2"}
        )
      ),
      build_entry(user_entry_json(%{"uuid" => "user-3"})),
      build_entry(
        assistant_entry_with_tools(
          [bash_tool_json(%{"id" => "bash_1"})],
          %{"uuid" => "assistant-3"}
        )
      )
    ]

    build_transcript(entries)
  end

  @doc """
  Creates a transcript with mixed text and tool content in entries.
  """
  def transcript_with_mixed_content do
    entries = [
      build_entry(user_entry_json()),
      build_entry(
        assistant_entry_with_text_and_tools(
          "Let me help you with that.",
          [read_tool_json(), edit_tool_json()]
        )
      )
    ]

    build_transcript(entries)
  end
end
