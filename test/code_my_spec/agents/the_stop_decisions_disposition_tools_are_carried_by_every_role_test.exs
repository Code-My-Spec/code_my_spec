defmodule CodeMySpec.Agents.TheStopDecisionsDispositionToolsAreCarriedByEveryRoleTest do
  @moduledoc """
  Issue `7507da80`, same shape as `e809c0db`
  (`the_answer_offer_names_a_tool_every_reader_carries_test.exs`): a sentence
  every role reads must not name a tool the narrowest reader does not carry.

  `Menu`'s `{:task, count}` directive -- the one printed when a role holds an
  open task -- tells the agent to close it with `evaluate_task`, or dispose
  of it with `ask_question`, `tap_out` or `cancel_task`. All three
  disposition tools are already registered, role-independently, by
  `LocalServer`'s `@spine`/`@unscriptable` lists -- confirmed by reading
  `CodeMySpec.McpServers.LibraryTools.call/4`, which gates a direct call on
  nothing but whether the tool is on that role-independent registration list.
  What was missing was `RoleProfile`'s own manifest: `ask_question` was
  listed for every role, but `tap_out` and `cancel_task` were not, so by this
  project's own established convention (`RoleProfile.carries?/2` is the
  single source of truth the test suite and the tool index both read) coding
  and qa read as unable to dispose of a task the directive had just told
  them to dispose of.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.RoleProfile

  # The two roles 7507da80 reports an active task for, and the only two
  # main's fix scoped: `@coding_tools`/`@qa_tools`. `:main` carries `:all`
  # by construction; whether `:product` should is a separate question this
  # issue does not answer, so this stays explicit rather than reaching for
  # `RoleProfile.roles()`.
  defp roles, do: [:coding, :qa]
  @disposition_tools ["ask_question", "tap_out", "cancel_task"]
  @menu_source "lib/code_my_spec/agents/menu.ex"

  describe "the {:task, count} directive text" do
    test "names all three disposition tools" do
      text = directive_text()

      Enum.each(@disposition_tools, fn name ->
        assert text =~ name,
               """
               the open-task directive no longer names `#{name}`:

                   #{text}
               """
      end)
    end
  end

  describe "every reader the directive is sent to" do
    test "carries all three disposition tools" do
      missing =
        for role <- roles(),
            name <- @disposition_tools,
            not RoleProfile.carries?(role, name),
            do: {role, name}

      assert missing == [],
             """
             the open-task directive tells these roles to dispose of a task
             with a tool RoleProfile says they do not carry, which loops the
             agent between "use this" and "you cannot" (7507da80):

             #{Enum.map_join(missing, "\n", fn {role, name} -> "  #{role}: #{name}" end)}
             """
    end
  end

  # The rendered directive text, from the module's own source -- the same
  # technique the e809c0db tests use, so this stays a unit test with no scope
  # and the class stays about the words.
  defp directive_text do
    source = File.read!(@menu_source)

    source
    |> then(&Regex.run(~r/defp directive\(scope, \{:task.*?(?=\n  # Tools are named)/s, &1))
    |> directive_block(source)
  end

  defp directive_block([block], _source), do: block

  defp directive_block(_miss, source),
    do: flunk("could not find the {:task, count} directive in #{source}")
end
