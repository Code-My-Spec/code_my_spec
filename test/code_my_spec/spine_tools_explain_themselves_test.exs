defmodule CodeMySpec.SpineToolsExplainThemselvesTest do
  @moduledoc """
  A script that reaches for a spine tool is told where it is.

  `Catalog`'s own comment says why this matters, and it was written before this
  happened: "attempt to call a nil value (global 'ask_user_question')" — which is what
  absence alone produces — "reads like a typo in the script rather than a rule
  about the tool. QA on story 970 found an agent would most likely try spelling
  variations rather than learn."

  The four spine tools were not in `@excluded`. They live on `LocalServer`
  rather than `ScriptableTools`, so `Catalog` never bound them and never
  explained them either — the one case the mechanism was built for and the one
  it did not cover.

  Observed 2026-09-05 on the broken_oaths main agent: it wrote
  `get_next_requirement()` inside `run_script` and got the bare Lua nil. That is
  the only recorded tool failure in a 357-message session.

  The reason they give is deliberately different from the others'. Those say a
  script *must not* do this; these say you already have it directly. An agent
  told the wrong reason looks in the wrong place.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.CodeMode.Catalog

  @spine ~w(get_next_requirement sync_project start_task evaluate_task)

  test "each spine tool is explained rather than absent" do
    for name <- @spine do
      assert name in Catalog.excluded(),
             "#{name} is not bound and not explained, so a script calling it gets " <>
               "`attempt to call a nil value` — which reads as a typo and sends the " <>
               "agent looking for a spelling that works."
    end
  end

  test "the reason points at the tool rather than forbidding it" do
    for name <- @spine do
      reason = Catalog.exclusion_reason(name)

      assert reason =~ "directly",
             "#{name}'s reason does not say where it actually is. These are not " <>
               "forbidden — they are already in hand, and an agent told 'a script " <>
               "may not' will stop trying to use a tool it is holding. Got: #{reason}"
    end
  end

  test "the tools a script genuinely must not call still say so" do
    # The distinction is the point: `ask_user_question` waits on a person and a loop
    # around it is questions nobody agreed to answer. That is a rule, not a
    # signpost, and collapsing the two would lose it.
    assert Catalog.exclusion_reason("ask_user_question") =~ "waits on a person"
    assert Catalog.exclusion_reason("run_script") =~ "already in one"
  end

  test "a spine tool is not also offered as callable" do
    callable = Catalog.excluded()

    for name <- @spine do
      assert name in callable,
             "#{name} would be bound and callable from a script as well as directly, " <>
               "which is two routes to one tool and a script paying Lua ceremony for " <>
               "the most-walked path in the product"
    end
  end
end
