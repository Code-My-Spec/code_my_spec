defmodule CodeMySpec.Transcripts.ClaudeCode.EntryTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Transcripts.ClaudeCode.Entry

  import CodeMySpec.TranscriptFixtures

  # ============================================================================
  # Local Fixture Helpers (build on shared fixtures)
  # ============================================================================

  defp user_entry do
    Entry.new(user_entry_json())
  end

  defp assistant_entry do
    Entry.new(assistant_entry_json())
  end

  defp assistant_entry_with_tool_use do
    Entry.new(assistant_with_tool_use_json(%{
      "message" => %{
        "role" => "assistant",
        "content" => [
          %{"type" => "text", "text" => "Let me read that file."},
          %{"type" => "tool_use", "id" => "tool_1", "name" => "Read", "input" => %{"file_path" => "/src/main.ex"}},
          %{"type" => "tool_use", "id" => "tool_2", "name" => "Grep", "input" => %{"pattern" => "def "}}
        ]
      }
    }))
  end

  defp user_entry_with_tool_results do
    Entry.new(user_with_tool_result_json(%{
      "message" => %{
        "role" => "user",
        "content" => [
          %{"type" => "tool_result", "tool_use_id" => "tool_1", "content" => "file contents here"},
          %{"type" => "tool_result", "tool_use_id" => "tool_2", "content" => "grep results here"}
        ]
      }
    }))
  end

  # ============================================================================
  # new/1
  # ============================================================================

  describe "new/1" do
    test "creates Entry from valid user message JSON" do
      entry = Entry.new(user_entry_json())

      assert %Entry{} = entry
      assert entry.type == "user"
      assert entry.uuid == "user-uuid-123"
      assert entry.session_id == "session-789"
      assert entry.message["role"] == "user"
      assert entry.message["content"] == "Hello, can you help me with this code?"
    end

    test "creates Entry from valid assistant message JSON" do
      entry = Entry.new(assistant_entry_json())

      assert %Entry{} = entry
      assert entry.type == "assistant"
      assert entry.uuid == "assistant-uuid-456"
      assert entry.parent_uuid == "user-uuid-123"
      assert entry.request_id == "req_abc123"
      assert entry.message["role"] == "assistant"
      assert is_list(entry.message["content"])
    end

    test "converts camelCase keys to snake_case struct fields" do
      json = %{
        "type" => "user",
        "uuid" => "test-uuid",
        "parentUuid" => "parent-uuid",
        "timestamp" => "2024-01-15T10:30:00Z",
        "sessionId" => "test-session",
        "agentId" => "test-agent",
        "gitBranch" => "feature-branch",
        "isSidechain" => true,
        "userType" => "internal",
        "requestId" => "req_test",
        "message" => %{}
      }

      entry = Entry.new(json)

      assert entry.parent_uuid == "parent-uuid"
      assert entry.session_id == "test-session"
      assert entry.agent_id == "test-agent"
      assert entry.git_branch == "feature-branch"
      assert entry.is_sidechain == true
      assert entry.user_type == "internal"
      assert entry.request_id == "req_test"
    end

    test "preserves message map structure" do
      message = %{
        "role" => "user",
        "content" => "test content",
        "custom_field" => %{"nested" => "value"}
      }

      json = user_entry_json(%{"message" => message})

      entry = Entry.new(json)

      assert entry.message == message
      assert entry.message["custom_field"]["nested"] == "value"
    end

    test "handles nil optional fields" do
      json = %{
        "type" => "user",
        "uuid" => "test-uuid",
        "timestamp" => "2024-01-15T10:30:00Z",
        "sessionId" => "test-session",
        "message" => %{"role" => "user", "content" => "test"}
      }

      entry = Entry.new(json)

      assert entry.parent_uuid == nil
      assert entry.agent_id == nil
      assert entry.cwd == nil
      assert entry.version == nil
      assert entry.git_branch == nil
      assert entry.is_sidechain == false
      assert entry.user_type == nil
      assert entry.request_id == nil
    end
  end

  # ============================================================================
  # user?/1
  # ============================================================================

  describe "user?/1" do
    test "returns true for user type entries" do
      entry = user_entry()

      assert Entry.user?(entry) == true
    end

    test "returns false for assistant type entries" do
      entry = assistant_entry()

      assert Entry.user?(entry) == false
    end
  end

  # ============================================================================
  # assistant?/1
  # ============================================================================

  describe "assistant?/1" do
    test "returns true for assistant type entries" do
      entry = assistant_entry()

      assert Entry.assistant?(entry) == true
    end

    test "returns false for user type entries" do
      entry = user_entry()

      assert Entry.assistant?(entry) == false
    end
  end

  # ============================================================================
  # content/1
  # ============================================================================

  describe "content/1" do
    test "returns string content for user entries" do
      entry = user_entry()

      assert Entry.content(entry) == "Hello, can you help me with this code?"
    end

    test "returns list of content blocks for assistant entries" do
      entry = assistant_entry()
      content = Entry.content(entry)

      assert is_list(content)
      assert length(content) == 1
      assert Enum.at(content, 0)["type"] == "text"
    end

    test "returns nil when message has no content field" do
      entry = Entry.new(%{
        "type" => "user",
        "uuid" => "test-uuid",
        "timestamp" => "2024-01-15T10:30:00Z",
        "sessionId" => "test-session",
        "message" => %{"role" => "user"}
      })

      assert Entry.content(entry) == nil
    end
  end

  # ============================================================================
  # role/1
  # ============================================================================

  describe "role/1" do
    test "returns \"user\" for user message entries" do
      entry = user_entry()

      assert Entry.role(entry) == "user"
    end

    test "returns \"assistant\" for assistant message entries" do
      entry = assistant_entry()

      assert Entry.role(entry) == "assistant"
    end

    test "returns nil when message has no role field" do
      entry = Entry.new(%{
        "type" => "user",
        "uuid" => "test-uuid",
        "timestamp" => "2024-01-15T10:30:00Z",
        "sessionId" => "test-session",
        "message" => %{"content" => "test"}
      })

      assert Entry.role(entry) == nil
    end
  end

  # ============================================================================
  # tool_use_blocks/1
  # ============================================================================

  describe "tool_use_blocks/1" do
    test "returns empty list for user entries" do
      entry = user_entry()

      assert Entry.tool_use_blocks(entry) == []
    end

    test "returns empty list for assistant entries with no tool use" do
      entry = Entry.new(assistant_entry_json(%{
        "message" => %{
          "role" => "assistant",
          "content" => [
            %{"type" => "text", "text" => "Just a text response."}
          ]
        }
      }))

      assert Entry.tool_use_blocks(entry) == []
    end

    test "returns list of tool_use blocks when present" do
      entry = assistant_entry_with_tool_use()
      blocks = Entry.tool_use_blocks(entry)

      assert length(blocks) == 2
      assert Enum.all?(blocks, fn block -> block["type"] == "tool_use" end)
    end

    test "preserves tool name and input from tool_use blocks" do
      entry = assistant_entry_with_tool_use()
      blocks = Entry.tool_use_blocks(entry)

      read_block = Enum.find(blocks, fn b -> b["name"] == "Read" end)
      grep_block = Enum.find(blocks, fn b -> b["name"] == "Grep" end)

      assert read_block["name"] == "Read"
      assert read_block["input"] == %{"file_path" => "/src/main.ex"}
      assert read_block["id"] == "tool_1"

      assert grep_block["name"] == "Grep"
      assert grep_block["input"] == %{"pattern" => "def "}
      assert grep_block["id"] == "tool_2"
    end
  end

  # ============================================================================
  # tool_result_blocks/1
  # ============================================================================

  describe "tool_result_blocks/1" do
    test "returns empty list for entries with string content" do
      entry = user_entry()

      assert Entry.tool_result_blocks(entry) == []
    end

    test "returns list of tool_result blocks when present" do
      entry = user_entry_with_tool_results()
      blocks = Entry.tool_result_blocks(entry)

      assert length(blocks) == 2
      assert Enum.all?(blocks, fn block -> block["type"] == "tool_result" end)
    end

    test "preserves tool_use_id and content from tool_result blocks" do
      entry = user_entry_with_tool_results()
      blocks = Entry.tool_result_blocks(entry)

      first_block = Enum.find(blocks, fn b -> b["tool_use_id"] == "tool_1" end)
      second_block = Enum.find(blocks, fn b -> b["tool_use_id"] == "tool_2" end)

      assert first_block["tool_use_id"] == "tool_1"
      assert first_block["content"] == "file contents here"

      assert second_block["tool_use_id"] == "tool_2"
      assert second_block["content"] == "grep results here"
    end
  end
end
