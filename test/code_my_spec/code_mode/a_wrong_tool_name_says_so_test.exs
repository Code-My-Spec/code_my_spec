defmodule CodeMySpec.CodeMode.AWrongToolNameSaysSoTest do
  @moduledoc """
  A name bound to nothing is told so, and told what to call instead.

  `Bindings` already makes this argument for the tools it deliberately
  withholds: absence "reads as a misspelling", so an agent "tries variations of
  the name instead of learning it is not for it", and each withheld tool gets a
  stub that explains itself. A name in no catalog at all had no stub and fell
  through to Lua's bare "attempt to call a nil value (global 'x')".

  That is the likeliest mistake in the browser sandbox, because its catalog is
  whatever the installed vibium publishes and an agent has read far more
  Playwright than vibium. Watched 2026-09-08: a QA agent went forty-five minutes
  without a successful tool call, on `browser_wait_for_timeout` — Playwright's
  `page.waitForTimeout`. `browser_sleep` was bound the entire time.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.CodeMode
  alias CodeMySpec.CodeMode.Catalog

  # Two tools is enough to be a catalog, and naming them for the real ones keeps
  # the suggestion assertion honest.
  defp catalog do
    Catalog.from(
      [
        %{name: "browser_sleep", description: "Wait a fixed number of milliseconds"},
        %{name: "browser_wait_for_text", description: "Wait until text appears"}
      ],
      fn _tool -> fn _args -> {:ok, "ok"} end end,
      nil
    )
  end

  defp run(script), do: CodeMode.eval(catalog(), script, [])

  test "an unbound name is named as unbound rather than as nil" do
    result = run(~s|return browser_wait_for_timeout({ timeout = 100 })|)

    assert result.error.message =~ "No tool is bound under that name"
  end

  test "and the message points at the catalog, called directly" do
    result = run(~s|return browser_wait_for_timeout({ timeout = 100 })|)

    assert result.error.message =~ "tool_docs",
           "an agent that is not told where the names live guesses again"

    assert result.error.message =~ "directly"
  end

  test "a near miss suggests the tool that is actually there" do
    result = run(~s|return browser_wait_for_txt({ text = "hi" })|)

    assert result.error.message =~ "browser_wait_for_text",
           "the catalog held a name one typo away and did not offer it"
  end

  # The Playwright case has no near neighbour by spelling — `browser_sleep` is
  # nothing like `browser_wait_for_timeout` — so the fallback has to carry its
  # own weight rather than suggesting something wrong.
  test "no near miss falls back to naming where the catalog is" do
    result = run(~s|return page_wait_for_timeout({})|)

    assert result.error.message =~ "tool_docs"
    refute result.error.message =~ "Did you mean"
  end

  test "an error that is not a missing global is left alone" do
    result = run(~s|error("something else went wrong")|)

    refute result.error.message =~ "No tool is bound under that name"
  end
end
