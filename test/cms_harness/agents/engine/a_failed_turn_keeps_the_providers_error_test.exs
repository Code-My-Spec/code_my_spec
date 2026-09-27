defmodule CmsHarness.Agents.Engine.AFailedTurnKeepsTheProvidersErrorTest do
  @moduledoc """
  044599cc: an exhausted codex account reached the transcript as "codex exec
  failed with status 1: OpenAI Codex v0.156.1" — exit status and version, with
  the provider's own sentence naming the limit and its reset date dropped.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Engine.Impl

  @usage_limit """
  codex exec failed with status 1: OpenAI Codex v0.156.1
  --------
  workdir: /tmp/copy
  model: gpt-6-astra
  --------
  ERROR: You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage
  to purchase more credits or try again at Sep 30th, 2026 11:20 PM.

  tokens used: 0
  """

  test "keeps the provider's error line, and the line it wraps onto" do
    text = Impl.failure_text(@usage_limit)

    assert text =~ "codex exec failed with status 1"
    assert text =~ "You've hit your usage limit"
    assert text =~ "try again at Sep 30th, 2026 11:20 PM."
    refute text =~ "tokens used"
  end

  test "output with no error line keeps only its first line" do
    assert Impl.failure_text("refused\nthe whole prompt quoted back") == "refused"
  end

  test "an {error: _} result reads its reason" do
    assert Impl.failure_text(%{error: @usage_limit}) =~ "usage limit"
  end
end
