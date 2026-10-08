defmodule CodeMySpec.Agents.TheAnswerOfferNamesAToolEveryReaderCarriesTest do
  @moduledoc """
  The answer offer names the tools, and every role that reads it carries them.

  Issue `e809c0db`, decided the other way on 2026-10-05. The first pass took
  option (b) — stop advertising, so `answer_offer/1` said "the reply reaches
  you" and named nothing. John's answer is (a): **carry both tools**. The offer
  is the only place an agent learns it can go and look for an answer it may
  have missed, and "the reply reaches you" describes a push that is not
  guaranteed — an agent whose turn ended before the answer landed has no way to
  find out from that sentence.

  So this asserts both halves of (a), which is what makes it different from
  `an_offer_does_not_name_a_tool_the_reader_lacks_test.exs` (that test asserts
  the words; this one asserts the grants):

    * `answer_offer/1` names `check_answer` and `list_user_questions` again.
    * every role that reads that text — the roles we run — carries both, so the
      sentence is true of the narrowest reader rather than of the widest.

  The failure this prevents is the one that produced the issue: a sentence
  every agent reads naming a tool the role does not have. Naming them without
  granting them is exactly that defect, and granting them without naming them
  is the push-only reading John rejected. Both halves move together or the
  issue is back.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.RoleProfile

  # Every role `RoleProfile` defines. Read from the module rather than listed
  # here: the point is that the offer is true of the narrowest *reader*, so a
  # role added later has to be covered by the assertion without this file
  # changing.
  defp roles, do: RoleProfile.roles()
  @polling_tools ["check_answer", "list_user_questions"]
  @offer_source "lib/code_my_spec/agents/menu.ex"

  describe "the offer text names the tools" do
    test "both polling tools are named" do
      text = offer_text()

      Enum.each(@polling_tools, fn name ->
        assert text =~ name,
               """
               the offer no longer names `#{name}`. John's answer is to carry
               both tools and say what to call — "the reply reaches you"
               describes a push, and an agent whose turn ended has no way to
               collect the answer from it.

                   #{text}
               """
      end)
    end
  end

  describe "every reader carries what the offer names" do
    test "each role that reads the offer carries both tools" do
      missing =
        for role <- roles(),
            name <- @polling_tools,
            not RoleProfile.carries?(role, name),
            do: {role, name}

      assert missing == [],
             """
             the offer names tools these roles do not carry, so the sentence is
             false for them and an agent will call what it cannot:

             #{Enum.map_join(missing, "\n", fn {role, name} -> "  #{role}: #{name}" end)}
             """
    end
  end

  # The rendered offer text, from the module's own source — the same technique
  # `an_offer_does_not_name_a_tool_the_reader_lacks_test.exs` uses, so this
  # stays a unit test with no scope and the class stays about the words.
  defp offer_text do
    source = File.read!(@offer_source)

    source
    |> then(&Regex.run(~r/defp answer_offer.*?(?=\n  defp open_questions)/s, &1))
    |> offer_block(source)
  end

  defp offer_block([block], _source), do: block
  defp offer_block(_miss, source), do: flunk("could not find answer_offer/1 in #{source}")
end
