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

  # 6880b4ab: a result that merely *contains* an invalid byte -- not from any
  # cut here, but already corrupt in stored content a tool rendered
  # verbatim, or produced by a caller's own byte-offset string slice -- took
  # the whole MCP session down at the JSON encoder, after whatever tool
  # calls ran before it had already committed. The short-circuit clause
  # (text already under the cap) returned such a result completely
  # unexamined; only the truncation clause ever checked validity at all.
  describe "an answer within the cap that is not valid UTF-8" do
    test "comes back valid instead of taking the session down" do
      text = "before" <> <<0xFF>> <> "after"

      capped = CodeMode.cap(text)

      assert String.valid?(capped)
    end

    test "keeps what surrounds the bad byte, not just a prefix" do
      # The old alternative -- trimming from the end until valid, the same
      # rule the truncation path uses -- would have thrown away "after"
      # entirely for a bad byte anywhere before it, which is wrong for text
      # that was never too long in the first place.
      capped = CodeMode.cap("before" <> <<0xFF>> <> "after")

      assert capped =~ "before"
      assert capped =~ "after"
    end

    test "an incomplete multi-byte sequence at the end is still handled" do
      # 0xE2 opens a 3-byte sequence (the em dash in this very file is
      # E2 80 94) and nothing follows it here.
      capped = CodeMode.cap("before" <> <<0xE2>>)

      assert String.valid?(capped)
      assert capped =~ "before"
    end

    test "valid UTF-8 within the cap is returned untouched" do
      text = "plain text with no bad bytes"

      assert CodeMode.cap(text) == text
    end
  end

  describe "both tools use this number" do
    test "the harness tool reports the same cap" do
      assert RunScript.max_result_chars() ==
               CodeMode.max_answer_bytes(),
             "two numbers is how the two paths came to disagree in the first place."
    end
  end

  describe "one implementation of the cut" do
    # b9632bba was two implementations of one rule, and fixing the number they
    # disagreed on left the *cutting* still copied three ways. Two of those
    # copies cut with `binary_part/3` and nothing else, so a cut landing inside
    # a multi-byte character handed back invalid UTF-8 — `run_browser_script`
    # on a page of prose and `call_mcp_server` on a `tools/list` are exactly
    # where multi-byte text arrives. An em-dash is `E2 80 94`, which is why
    # this surfaces as `invalid byte 0xE2` at the encoder rather than anywhere
    # near the tool that produced it.
    #
    # Scanning the source rather than calling the functions because both are
    # private, and the property is "nobody writes a second one", which a
    # behavioural test on the one that exists cannot express.
    @lib_root Path.expand("../../../lib", __DIR__)

    test "only CodeMode builds the truncation note" do
      authors =
        @lib_root
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.filter(fn path ->
          path |> File.read!() |> String.contains?("[truncated — the answer was longer than")
        end)
        |> Enum.map(&Path.relative_to(&1, @lib_root))

      assert authors == ["code_my_spec/code_mode.ex"],
             "a second module builds the note, which means it also does its own " <>
               "cutting: #{inspect(authors)}. Call `CodeMode.cap/1` instead — it is " <>
               "the one that trims back to a valid UTF-8 boundary."
    end
  end
end
