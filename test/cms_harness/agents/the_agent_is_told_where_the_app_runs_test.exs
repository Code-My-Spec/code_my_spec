defmodule CmsHarness.Agents.TheAgentIsToldWhereTheAppRunsTest do
  @moduledoc """
  An agent that cannot answer "where is the app" cannot open it.

  The address is a column — `working_copies.preview_url`, written when the
  harness brings a preview up — so nothing on the machine side can work it out.
  On 2026-09-07 the war-epic QA agent had the browser bound and 77 tools ready
  and reported: "no app URL has been identified. I will not try to start it."
  It was right to refuse, and the app was up the whole time behind a tunnel
  nobody had told it about.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Agents.SystemPrompt

  @url "https://preview-c8eda3e8.codemyspec.com"

  test "the prompt names the address" do
    prompt = SystemPrompt.compose("You are QA.", nil, @url)

    assert prompt =~ @url
    assert prompt =~ "running at"
  end

  test "it says the address belongs to the main checkout" do
    prompt = SystemPrompt.compose("You are QA.", nil, @url)

    # A QA agent works in a worktree and the preview is the main copy's —
    # `record_preview_url/2` refuses any other. Without saying so, an agent in a
    # worktree reasonably assumes the URL serves the tree it is editing.
    assert prompt =~ "main checkout"
    assert prompt =~ "does not serve one"
  end

  # Nil says nothing rather than "there is no app". A project between previews
  # looks identical from here to one that never had them, and only one of those
  # is worth telling an agent.
  test "no address says nothing about the app" do
    prompt = SystemPrompt.compose("You are QA.", nil, nil)

    assert prompt == "You are QA."
    refute prompt =~ "running at"
  end

  test "an empty address is the same as none" do
    assert SystemPrompt.compose("You are QA.", nil, "") == "You are QA."
  end

  # The brief is still the first thing, and the address is context for it
  # rather than a replacement.
  test "the role brief comes first" do
    prompt = SystemPrompt.compose("You are QA.", nil, @url)

    assert String.starts_with?(prompt, "You are QA.")
  end

  # It stays optional, so every existing caller keeps working.
  test "composing without an address is unchanged" do
    assert SystemPrompt.compose("You are QA.", nil) == "You are QA."
  end
end
