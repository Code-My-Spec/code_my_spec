defmodule CodeMySpec.Files.PersonaSourcesRuleTest do
  @moduledoc """
  A source entry names something you can go back to.

  Issue 1d9bbf6a: the validator required a URL *and* a YYYY-MM-DD date on the
  same physical line, the error message said "URL or date", and
  `agent_personas.md` documented the format with a URL-less codebase citation
  that also wrapped — so it failed twice over, and following the playbook
  produced a file that could not validate. `orchestrating-main-agent` sat with
  23 failing entries and `personas_complete` unsatisfied because of it.

  The fix applied at the time was to rewrite every sources file into
  URL-and-date form. That made the symptom go away and left the rule wrong, so
  these tests are against the rule rather than against any file.

  The rule, decided by the owner: a URL or a file path. The date is optional.
  Most of what a persona cites is an agent definition, an MCP registration or a
  log observation — for those the locator is the reproducible part, and a path
  with a SHA beside it says more about what was read than the day somebody read
  it.
  """

  use ExUnit.Case, async: true

  import CodeMySpec.EnvironmentFixtures

  alias CodeMySpec.Environments
  alias CodeMySpec.Files.Scanner

  @path ".code_my_spec/personas/x/sources.md"

  # Through `validate_entry/4`, which is the surface a sync calls — the
  # validator itself is private, and a test that reached around it would be
  # asserting on a function production does not use.
  defp validate(content) do
    env = memory_environment_fixture()
    :ok = Environments.write_file(env, @path, content)

    Scanner.validate_entry(%{role: :persona_sources, path: @path}, env, %{})
  end

  defp errors(content), do: validate(content).validation_errors["errors"]["sources"]
  defp entry_count(content), do: validate(content).validation_errors["data"]["entry_count"]

  describe "what counts as a source" do
    test "the playbook's own example validates" do
      # Verbatim from priv/knowledge/persona_research/agent_personas.md. It is
      # the format the guide teaches, and the guide is what an agent follows.
      content = """
      # Sources

      - `CodeMySpec/agents/qa.md` @ a7a0bf53 — declared tool list and
        system prompt for the QA agent. Accessed 2026-05-17.
      - https://modelcontextprotocol.io/specification/2025-03-26 — MCP
        tools/call contract. Accessed 2026-05-17.
      - `.code_my_spec/qa/607/result.md` @ a7a0bf53 — observed agent
        output for a per-story QA run. Accessed 2026-05-17.
      """

      assert errors(content) == nil,
             "the guide's own example is rejected, so following the playbook " <>
               "produces a file that cannot validate. That is the whole of 1d9bbf6a."

      assert entry_count(content) == 3
    end

    test "a path with no date is enough" do
      content = "- `lib/code_my_spec/agents.ex` @ fb804066 — the launch path.\n"

      assert errors(content) == nil,
             "the date was made optional deliberately: a log observation has no " <>
               "URL and never will, and the path plus SHA is the reproducible part."
    end

    test "a URL with no date is enough" do
      assert errors("- https://modelcontextprotocol.io/specification/2025-03-26 — it.\n") == nil
    end

    test "a claim that names nothing is rejected" do
      content = "- The QA agent has a deliberately narrow tool list. Accessed 2026-05-17.\n"

      assert errors(content) =~ "no URL or file path"

      refute errors(content) =~ "YYYY-MM-DD",
             "the message still describes the old rule, which is how the message " <>
               "and the code came to disagree in the first place."
    end

    test "prose containing a slash is not a path" do
      content = "- Whether the agent reports success and/or failure was unclear.\n"

      assert errors(content) =~ "no URL or file path",
             "`and/or` has a slash in it and names nothing. Requiring a file " <>
               "extension after the slash is what keeps prose out."
    end

    test "an empty list is still an error" do
      assert errors("# Sources\n\nNothing yet.\n") =~ "no entries"
    end
  end

  describe "a wrapped bullet is one entry" do
    test "a locator on a continuation line counts" do
      content = """
      - Declared tool list and system prompt for the QA agent, read at
        `CodeMySpec/agents/qa.md` @ a7a0bf53.
      """

      assert errors(content) == nil,
             "splitting on newlines judged the first line and never saw the rest, " <>
               "so a citation that wrapped was rejected for lacking what it had."

      assert entry_count(content) == 1
    end

    test "a continuation is not counted as its own entry" do
      content = """
      - https://example.com/a — first source, with a title long enough
        that it wraps onto a second line.
      - https://example.com/b — second source.
      """

      assert entry_count(content) == 2,
             "the wrapped remainder was counted as a source of its own, which " <>
               "inflates the count a persona is judged complete on."
    end

    test "a flush-left paragraph after a bullet is not swallowed" do
      content = """
      - https://example.com/a — a source.

      This paragraph is prose, not part of the entry above it.

      - https://example.com/b — another source.
      """

      assert errors(content) == nil
      assert entry_count(content) == 2
    end
  end
end
