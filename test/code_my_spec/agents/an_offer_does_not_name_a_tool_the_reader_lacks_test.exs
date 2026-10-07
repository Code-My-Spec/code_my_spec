defmodule CodeMySpec.Agents.AnOfferDoesNotNameAToolTheReaderLacksTest do
  @moduledoc """
  The offer names the polling tools, and no role that reads it lacks them.

  Issue `e809c0db`, decided as (a) on 2026-10-05: **carry both tools**. This file
  was written for the first pass, option (b) — stop advertising, so
  `answer_offer/1` said "the reply reaches you" and named nothing. John reversed
  it, so the assertion does too.

  What survives the reversal is the half that was never about wording: a sentence
  every agent reads must not name a tool the narrowest reader does not carry.
  Option (b) satisfied that by dropping the names; option (a) satisfies it by
  granting them. Both are the same test — the names are in the offer, and every
  reader carries them — and it is written against the role's grants rather than
  the phrasing, so the next sentence that names an uncarried tool fails here
  rather than on a live agent's turn.

  `tool_docs` is untouched by the reversal: its half of the issue was that it
  asserted "its schema is already in your tool list" for a caller that may not
  have it, and the answer there is still to say whether the caller carries it.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.RoleProfile

  # Every role we run, read from the module rather than listed here: the offer
  # text is shared by all of them, so it has to be true of the narrowest, and a
  # role added later has to be covered without this file changing.
  defp roles, do: RoleProfile.roles()

  @offer_source "lib/code_my_spec/agents/menu.ex"
  @docs_source "lib/code_my_spec/mcp_servers/code_mode/tools/tool_docs.ex"

  # The tools this issue is about: real, direct-call-only, and named in the
  # offer every agent reads.
  @polling_tools ["check_answer", "list_user_questions"]

  describe "the offer text an agent reads" do
    test "names both polling tools" do
      text = offer_text()

      Enum.each(@polling_tools, fn name ->
        assert text =~ name,
               """
               the offer does not name `#{name}`. Decision (a) is to carry both
               tools *and* say what to call: "the reply reaches you" describes a
               push, and an agent whose turn ended before the answer landed has
               no way to collect it from that sentence.

                   #{text}
               """
      end)
    end

    test "names no tool any reader lacks" do
      text = offer_text()

      named =
        Enum.filter(@polling_tools, fn name ->
          String.contains?(text, name) and
            Enum.any?(roles(), fn role -> not RoleProfile.carries?(role, name) end)
        end)

      assert named == [],
             """
             The answer offer names #{Enum.join(named, ", ")}, which at least one
             role does not carry. An agent reads this every turn and will call it.

                 #{text}
             """
    end

    test "still says the reply reaches the agent" do
      text = offer_text()

      assert text =~ ~r/repl(y|ies)/i,
             "the offer no longer tells the agent how it learns an answer landed"
    end
  end

  describe "the direct page tool_docs renders" do
    test "does not assert the schema is in the caller's tool list unconditionally" do
      source = File.read!(@docs_source)

      refute source =~ ~r/its schema is\s+already in your tool list/,
             """
             #{@docs_source} still tells every caller the tool is in its list.
             Whether it is depends on the role, which the page can now say.
             """
    end

    test "says whether the caller carries the tool" do
      source = File.read!(@docs_source)

      assert source =~ "carries" or source =~ "carry",
             "the direct page should distinguish 'you carry it' from 'you do not'"
    end
  end

  # The rendered offer text, from the module's own source. The text is built by
  # string concatenation over three clauses; reading the source is what keeps
  # this a unit test with no scope, and the class is about the words.
  defp offer_text do
    source = File.read!(@offer_source)

    source
    |> then(&Regex.run(~r/defp answer_offer.*?(?=\n  defp open_questions)/s, &1))
    |> offer_block(source)
  end

  defp offer_block([block], _source), do: block
  defp offer_block(_miss, source), do: flunk("could not find answer_offer/1 in #{source}")
end
