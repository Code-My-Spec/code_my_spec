defmodule CmsHarness.Agents.SystemPromptTest do
  @moduledoc """
  An agent is told what it is for, and what this project's workflow is.

  Before this, `system_prompt` was never set: `Alloy.Agent.Config` defaults it
  to nil and no caller supplied one, so an agent's role picked its tools and
  told it nothing. Asked what its job was, a live product agent answered "My job
  was to call `list_epics` and reply with exactly its result." Issue
  `0f022a10`.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.Agents.SystemPrompt
  alias CodeMySpec.Agents.LaunchRequest
  alias CodeMySpec.Agents.RoleBrief

  defp copy_with_guide(contents) do
    {:ok, dir} = Briefly.create(directory: true)
    File.mkdir_p!(Path.join(dir, ".code_my_spec"))
    File.write!(Path.join(dir, ".code_my_spec/AGENTS.md"), contents)
    dir
  end

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

      request = LaunchRequest.for(agent)

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

      request = LaunchRequest.for(agent)

      assert Map.has_key?(request, "role_brief")
      assert request["role_brief"] == nil
    end
  end

  describe "composing" do
    test "the agent gets its role first and the project's workflow after" do
      dir = copy_with_guide("# Project Guide\n\nThe core loop is X.")

      prompt = SystemPrompt.compose(RoleBrief.for(:coding), dir)

      assert prompt =~ "You are the CODING agent"
      assert prompt =~ "The core loop is X."

      assert :binary.match(prompt, "You are the CODING agent") <
               :binary.match(prompt, "The core loop is X."),
             "the project guide came before the role, so the agent reads workflow before purpose"
    end

    test "a checkout with no guide still tells the agent what it is" do
      {:ok, dir} = Briefly.create(directory: true)

      prompt = SystemPrompt.compose(RoleBrief.for(:qa), dir)

      assert prompt =~ "You are the QA agent"
      refute prompt =~ "AGENTS.md"
    end

    test "nothing to say is nil, not an empty prompt" do
      {:ok, dir} = Briefly.create(directory: true)

      assert SystemPrompt.compose(nil, dir) == nil
      assert SystemPrompt.compose(nil, nil) == nil
    end

    test "an oversized guide is dropped rather than charged on every turn" do
      dir = copy_with_guide(String.duplicate("x", 70 * 1024))

      prompt = SystemPrompt.compose(RoleBrief.for(:main), dir)

      assert prompt =~ "You are the MAIN agent",
             "the role brief must survive a guide that does not"

      refute prompt =~ "xxxxxxxxxx", """
      A 70KB guide was sent. A system prompt is charged on every turn, so one
      that has quietly become a codebase is an expensive thing to discover from
      a bill rather than from a log line.
      """
    end
  end
end
