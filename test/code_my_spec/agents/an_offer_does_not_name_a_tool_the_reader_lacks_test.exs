defmodule CodeMySpec.Agents.AnOfferDoesNotNameAToolTheReaderLacksTest do
  @moduledoc """
  An offer describes what happens, not what to call.

  Issue `e809c0db`. Two surfaces told every agent to call tools a correctly
  configured agent does not and should not carry:

    * `Validation.Menu.answer_offer/1` named `check_answer` and
      `list_user_questions` unconditionally, in the nudge an agent reads every
      turn. Answers are pushed to an agent we run, so there is nothing for it
      to poll for and neither tool is carried. An agent primed by that sentence
      called one, was refused, and stopped.
    * `tool_docs` described a direct-only tool as "its schema is already in your
      tool list" — true for Claude Code, false for an Alloy agent that does not
      carry the name.

  The decision is (b): stop advertising. The reply reaching the agent is the
  behaviour worth stating, and it is true of both kinds of agent; naming the
  tool is the part that is true of only one. The same for `tool_docs`: it says
  whether the caller carries a tool rather than asserting that it does.

  ## Why a test rather than the two edits

  The class is "a sentence an agent reads names a tool its role does not
  carry", and it has recursed. Carrying the tool instead (`3bc106f6` did that
  for these two) makes the sentence true and pays a schema on every turn of
  every role. The assertion is written against the role's grants, not the
  wording, so the next sentence that names an uncarried tool fails here rather
  than on a live agent's turn.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.RoleProfile

  # What every agent we run is, and what each carries. The offer text is shared
  # by all of them, so it has to be true of the narrowest.
  @roles [:main, :coding, :qa, :product, :researcher, :spec_writer, :test_writer, :bdd_spec_writer]

  @offer_source "lib/code_my_spec/agents/menu.ex"
  @docs_source "lib/code_my_spec/mcp_servers/code_mode/tools/tool_docs.ex"

  # The tools this issue is about: real, direct-call-only, and not carried by
  # an agent we run. `semantic_search` is scriptable, so the answer for it is
  # that it is not presented as directly-callable at all.
  @polling_tools ["check_answer", "list_user_questions"]

  describe "the offer text an agent reads" do
    test "names no tool a role does not carry" do
      text = offer_text()

      named =
        @polling_tools
        |> Enum.filter(&String.contains?(text, &1))
        |> Enum.filter(fn name ->
          Enum.any?(@roles, fn role -> not RoleProfile.carries?(role, name) end)
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
