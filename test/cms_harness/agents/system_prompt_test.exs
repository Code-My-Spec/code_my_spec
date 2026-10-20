defmodule CmsHarness.Agents.SystemPromptTest do
  @moduledoc """
  An agent is told the loop it runs, what this project is, and what it is for —
  in that order, general to specific.

  Before this, `system_prompt` was never set: `Alloy.Agent.Config` defaults it
  to nil and no caller supplied one, so an agent's role picked its tools and
  told it nothing. Asked what its job was, a live product agent answered "My job
  was to call `list_epics` and reply with exactly its result." Issue
  `0f022a10`.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.Agents.SystemPrompt
  alias CodeMySpec.Agents.LaunchRequest
  alias CodeMySpec.Agents.OperatingRules
  alias CodeMySpec.Agents.ProviderBrief
  alias CodeMySpec.Agents.RoleBrief
  alias CodeMySpec.McpServers.ToolRegistry

  describe "role briefs" do
    test "every role the tool sets scope has something to say about itself" do
      for role <- [:main, :product, :coding, :qa] do
        brief = RoleBrief.for(role)

        assert is_binary(brief) and brief != "",
               "#{role} has a scoped tool set and no brief, so it gets tools it is never told about"

        assert brief =~ ~r/you are the/i, "#{role}'s brief does not tell it what it is"
      end
    end

    test "the product brief says the thing that cost a live agent its turns" do
      brief = RoleBrief.for(:product)

      assert brief =~ "do not write application code"

      assert brief =~ "belongs to whoever wrote it", """
      The product brief does not tell the agent that findings in files it did
      not edit are not its to fix. That is exactly what a real one did: it was
      handed 160 credo findings and spent every turn clearing somebody else's
      backlog.
      """
    end

    test "a role nobody has written down gets nothing rather than something vague" do
      assert RoleBrief.for(:unknown_role) == nil
      assert RoleBrief.for("not_a_real_role") == nil
      assert RoleBrief.for(nil) == nil
    end

    test "a role arriving as a string resolves the same as an atom" do
      assert RoleBrief.for("product") == RoleBrief.for(:product)
    end
  end

  describe "the wire" do
    # The composer being right proves nothing if the brief never leaves the
    # server. Twice tonight a correct function sat behind a flag nobody set —
    # once for `internal_agent?`, once for the whole of edit tracking — and both
    # times the unit test passed because it called the function directly.
    test "the launch request carries the brief for the agent's role" do
      agent = %CodeMySpec.Agents.Agent{
        id: Ecto.UUID.generate(),
        engine: :alloy,
        provider: "openai-codex",
        role: :product,
        working_copy: "/tmp/a-copy"
      }

      request = LaunchRequest.for(agent, ToolRegistry.registry())

      assert request["role_brief"] == RoleBrief.for(:product), """
      The launch request does not carry the role brief, so the harness has
      nothing to compose and every agent starts with no system prompt — which is
      the state this fixed.
      """
    end

    test "an agent whose role has no brief still produces a valid request" do
      agent = %CodeMySpec.Agents.Agent{
        id: Ecto.UUID.generate(),
        engine: :alloy,
        provider: "openai-codex",
        role: nil,
        working_copy: "/tmp/a-copy"
      }

      request = LaunchRequest.for(agent, ToolRegistry.registry())

      assert Map.has_key?(request, "role_brief")
      assert request["role_brief"] == nil
    end
  end

  describe "composing" do
    test "the three sections arrive general to specific" do
      prompt =
        SystemPrompt.compose(
          universal: "UNIVERSAL-SECTION",
          app_url: "https://example.test",
          tool_index: "TOOL-SECTION",
          role_brief: RoleBrief.for(:coding)
        )

      positions = [
        {"universal", :binary.match(prompt, "UNIVERSAL-SECTION") |> elem(0)},
        {"app url", :binary.match(prompt, "https://example.test") |> elem(0)},
        {"tool index", :binary.match(prompt, "TOOL-SECTION") |> elem(0)},
        {"role", :binary.match(prompt, "You are the CODING agent") |> elem(0)}
      ]

      assert positions == Enum.sort_by(positions, &elem(&1, 1)), """
      The sections are out of order. A model reads the top of a prompt hardest,
      so the loop has to come before what the agent is, not after it. Got:
      #{inspect(positions)}
      """
    end

    test "the loop reaches the agent without any file on disk" do
      # The bug this whole ordering exists to remove. The loop used to live only
      # in `.code_my_spec/AGENTS.md`, read off the working copy — and story
      # 1039's eval builds its checkout with `File.mkdir_p!` and nothing else,
      # so the agent was measured on a prompt that never told it to claim work.
      prompt = SystemPrompt.compose(universal: OperatingRules.text())

      assert prompt =~ "get_next_requirement"
      assert prompt =~ "start_task"

      assert :binary.match(prompt, "get_next_requirement") <
               :binary.match(prompt, "start_task"),
             "the loop must name asking before claiming — that is the order it asserts"
    end

    test "a section with nothing in it contributes nothing" do
      prompt =
        SystemPrompt.compose(
          universal: "RULES",
          app_url: nil,
          tool_index: "",
          role_brief: RoleBrief.for(:qa)
        )

      assert prompt =~ "RULES"
      assert prompt =~ "You are the QA agent"
      refute prompt =~ "The project"
      refute prompt =~ "running at"
    end

    test "the scratch directory is told to the agent, between the app url and the tool index" do
      prompt =
        SystemPrompt.compose(
          app_url: "https://example.test",
          scratch_dir: "/var/cms/agent_scratch/abc123",
          tool_index: "TOOL-SECTION"
        )

      assert prompt =~ "/var/cms/agent_scratch/abc123"

      assert :binary.match(prompt, "https://example.test") <
               :binary.match(prompt, "/var/cms/agent_scratch/abc123") and
               :binary.match(prompt, "/var/cms/agent_scratch/abc123") <
                 :binary.match(prompt, "TOOL-SECTION"),
             "the scratch directory belongs with the rest of §2, before the tool index"
    end

    test "no scratch directory contributes nothing" do
      prompt = SystemPrompt.compose(universal: "RULES", scratch_dir: nil)

      refute prompt =~ "read back"
    end

    test "nothing to say is nil, not an empty prompt" do
      assert SystemPrompt.compose([]) == nil
      assert SystemPrompt.compose(universal: nil, role_brief: nil) == nil
      assert SystemPrompt.compose(universal: "", tool_index: "   ") == nil
    end

    test "a provider brief reads after the index it is about" do
      # `claude-code` emulates tool calling: the definitions are serialised into
      # the request as `available_tools` rather than offered natively. An agent
      # that is wrong about that does not fail loudly — it reports its tools
      # missing and stops, which reads as declining work.
      #
      # Agents are taught that shape by demonstration now rather than in prose:
      # `LaunchRequest` seeds a direct call and a nested one into their history,
      # and `ProviderBrief.for/1` answers nil unless `CMS_PROVIDER_BRIEF=1` puts
      # the text back. What is asserted here is the ordering contract that holds
      # whenever a brief is given at all — it explains the list, so it reads
      # after it.
      prompt =
        SystemPrompt.compose(
          tool_index: "## Tools you can reach\n\n**Called directly:** run_script",
          provider_brief: "Your tools arrive as `available_tools`.",
          role_brief: RoleBrief.for(:main)
        )

      assert :binary.match(prompt, "Tools you can reach") <
               :binary.match(prompt, "available_tools"),
             "the brief is about the index, so it reads after it"
    end

    test "a provider whose tool calling needs no explanation gets none" do
      assert ProviderBrief.for("anthropic") == nil
      assert ProviderBrief.for(nil) == nil

      prompt =
        SystemPrompt.compose(provider_brief: ProviderBrief.for("zai"), role_brief: "You are QA.")

      assert prompt == "You are QA."
    end

    test "a map composes the same as a keyword list" do
      parts = [universal: "RULES", role_brief: RoleBrief.for(:main)]

      assert SystemPrompt.compose(parts) == SystemPrompt.compose(Map.new(parts))
    end
  end
end
