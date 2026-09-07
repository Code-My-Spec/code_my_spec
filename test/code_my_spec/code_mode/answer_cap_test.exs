defmodule CodeMySpec.CodeMode.AnswerCapTest do
  @moduledoc """
  One cap, one number, and it applies to the consumer that needed it most.

  Issue b9632bba. `CmsHarness.Agents.Tools.RunScript` cut at 24,000 characters
  and said so. The server tool it calls through did not cut at all — and that
  is the path every Claude Code session in a project reaches over the plugin's
  MCP mount. Asked for sixty thousand characters through :4004, sixty thousand
  arrived, with nothing in the transcript saying the reply was large.

  So the consumer with the tighter context window was the one with no cap, and
  the reason is that one rule had two implementations. There is one now, in
  `CodeMode`, and both tools call it.

  `CodeMode`'s moduledoc has claimed "a script cannot build an answer too big to
  carry" the whole time. The sandbox bounds what a script may *build* —
  instruction budget, call depth, Lua's own string limit — and none of them
  bound what it may *return*. `string.rep("x", 60000)` breaks no limit while
  building.

  The issue also noted the cap was untested on either path: a module attribute
  and a private function, with no test naming either. The half that worked,
  worked by inspection.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Tools.RunScript
  alias CodeMySpec.CodeMode

  describe "an answer within the cap" do
    test "is returned untouched" do
      text = String.duplicate("x", 100)

      assert CodeMode.cap(text) == text
    end

    test "an answer of exactly the cap is not cut" do
      text = String.duplicate("x", CodeMode.max_answer_bytes())

      assert CodeMode.cap(text) == text,
             "an off-by-one here spends the note's 60-odd characters on an answer " <>
               "that already fit."
    end
  end

  describe "an answer over the cap" do
    test "comes back no larger than the cap" do
      capped = CodeMode.cap(String.duplicate("x", 60_000))

      assert byte_size(capped) <= CodeMode.max_answer_bytes(),
             "this is the reported case exactly: 60,015 bytes asked for and " <>
               "60,015 delivered."
    end

    test "says it was cut" do
      capped = CodeMode.cap(String.duplicate("x", 60_000))

      assert capped =~ "truncated",
             "cutting silently is worse than not cutting — the agent reasons about " <>
               "a fragment as though it were the whole answer, and nothing in the " <>
               "transcript says otherwise."
    end

    test "keeps the beginning of the answer" do
      capped = CodeMode.cap("the useful part comes first" <> String.duplicate("x", 60_000))

      assert String.starts_with?(capped, "the useful part comes first")
    end
  end

  describe "cutting a multi-byte answer" do
    test "the result is still valid UTF-8" do
      # `binary_part/3` splits on bytes. A cut landing inside a multi-byte
      # character produces a binary that is no longer valid UTF-8, which travels
      # as far as the JSON encoder and fails there — turning a large answer into
      # no answer at all, which is a worse outcome than the one being fixed.
      capped = CodeMode.cap(String.duplicate("日", 30_000))

      assert String.valid?(capped)
      assert byte_size(capped) <= CodeMode.max_answer_bytes()
    end

    test "an answer that is one long emoji run still cuts cleanly" do
      capped = CodeMode.cap(String.duplicate("🔥", 20_000))

      assert String.valid?(capped)
      assert capped =~ "truncated"
    end
  end

  describe "both tools use this number" do
    test "the harness tool reports the same cap" do
      assert RunScript.max_result_chars() ==
               CodeMode.max_answer_bytes(),
             "two numbers is how the two paths came to disagree in the first place."
    end
  end
end
