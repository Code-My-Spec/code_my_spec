defmodule CmsHarness.Agents.ProviderTest do
  @moduledoc """
  What reaches the provider, and what must not.

  Both failures covered here shipped, and both were invisible to everything
  that did not run a turn — which was everything, until a criterion started
  running one against a real endpoint.

    * The options were flat: `provider: Module` with `api_key:` and `model:`
      beside it. `Alloy.Agent.Config` reads `:provider` as `{module, config}`
      and keeps only the config half, dropping every sibling it does not
      recognise, so the first request raised `key :model not found` from inside
      the provider.

    * The codex clause defaulted to `gpt-5.4`, and a ChatGPT account answers
      *"The 'gpt-5.4' model is not supported when using Codex with a ChatGPT
      account"*. A plan decides which models it serves; naming one here is a
      guess about somebody else's subscription.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Provider

  describe "the shape Alloy actually reads" do
    test "a provider's settings live in the config half of the tuple" do
      {:ok, opts} = Provider.options("zai", %{api_key: "k"})

      assert {Alloy.Provider.OpenAICompat, config} = Keyword.fetch!(opts, :provider)
      assert config.api_key == "k"
      assert config.model
      assert config.api_url

      refute Keyword.has_key?(opts, :api_key),
             "a setting beside the module is dropped by Alloy without a word, " <>
               "which is how a provider that had never run a turn looked configured"
    end
  end

  describe "where a subprocess provider runs" do
    # 5001c099: codex got no workdir and ran in Alloy's temp dir.
    test "codex and claude-code both run in the working copy" do
      for provider <- ["openai-codex", "claude-code"] do
        {:ok, opts} = Provider.options(provider, %{}, working_copy: "/tmp/copy")
        {_module, config} = Keyword.fetch!(opts, :provider)

        assert config.workdir == "/tmp/copy", "#{provider} did not get the working copy"
      end
    end
  end

  # eb09b076: `claude -p` compacting a ~1M-token resumed session took about
  # 180s, the old wall clock was 180s, and every retry re-ran the same
  # compaction into the same kill.
  describe "how long one codex call may run" do
    test "as long as a claude-code call: a turn runs whole test files and spex" do
      {:ok, codex} = Provider.options("openai-codex", %{}, timeout_ms: nil)
      {:ok, claude} = Provider.options("claude-code", %{}, timeout_ms: nil)
      {Alloy.Provider.Codex, codex_config} = Keyword.fetch!(codex, :provider)
      {AlloyClaudeCode, claude_config} = Keyword.fetch!(claude, :provider)

      assert codex_config.timeout_ms == claude_config.timeout_ms
    end
  end

  # Team 3's coder grew past codex's 1,048,576-character prompt cap before
  # Alloy compacted, and every turn failed on it (2026-10-14).
  describe "how much a codex agent may carry before it compacts" do
    test "compaction comes well before codex's prompt cap" do
      {:ok, opts} = Provider.options("openai-codex", %{})
      config = Alloy.Agent.Config.from_opts(opts)

      compacts_at_chars = (config.max_tokens - config.compaction.reserve_tokens) * 4

      assert compacts_at_chars < 1_048_576 * 0.6,
             "the transcript can reach #{compacts_at_chars} characters before compacting, " <>
               "leaving too little of codex's 1,048,576-character cap for the system " <>
               "prompt, tool definitions and schema a fresh thread also sends"
    end
  end

  describe "how long one claude-code call may run" do
    test "long enough for the CLI to compact a full session" do
      {:ok, opts} = Provider.options("claude-code", %{}, timeout_ms: nil)
      {AlloyClaudeCode, config} = Keyword.fetch!(opts, :provider)

      assert config.timeout_ms >= :timer.minutes(10)
    end

    test "a timeout it was given reaches the provider" do
      {:ok, opts} = Provider.options("claude-code", %{}, timeout_ms: 45_000)
      {AlloyClaudeCode, config} = Keyword.fetch!(opts, :provider)

      assert config.timeout_ms == 45_000
    end
  end

  describe "which model an agent asks for" do
    test "a codex agent names none unless one was asked for" do
      {:ok, opts} = Provider.options("openai-codex", %{})
      {Alloy.Provider.Codex, config} = Keyword.fetch!(opts, :provider)

      refute config.model,
             "a hardcoded model is a guess about the account's plan. This shipped " <>
               "as gpt-5.4 and every codex agent on a ChatGPT account failed its " <>
               "first turn on a model that account does not serve."
    end

    test "a codex agent borrows the home's login, not its config" do
      {:ok, opts} = Provider.options("openai-codex", %{})
      {Alloy.Provider.Codex, config} = Keyword.fetch!(opts, :provider)

      assert config.codex_home == Path.expand("~/.codex")

      # Alloy ignores the home's config.toml unless a profile is named.
      refute Map.has_key?(config, :profile),
             "the home's config.toml brings its owner's plugins, MCP servers, approval " <>
               "reviewer and default model to every call"
    end

    test "a codex agent resumes its own thread and runs no command of its own" do
      {:ok, opts} = Provider.options("openai-codex", %{}, working_copy: "/tmp/copy")
      {Alloy.Provider.Codex, config} = Keyword.fetch!(opts, :provider)

      assert config.persist_session
      assert config.workdir == "/tmp/copy"
      assert "features.shell_tool=false" in config.config_overrides
      assert "features.unified_exec=false" in config.config_overrides
    end

    # Issue 199e6ac1: told its sandbox was read-only, a Codex coder refused to
    # ask for the outer Edit/Write tools at all.
    test "a codex agent is not told it cannot write" do
      {:ok, opts} = Provider.options("openai-codex", %{})
      {Alloy.Provider.Codex, config} = Keyword.fetch!(opts, :provider)

      assert "include_permissions_instructions=false" in config.config_overrides
    end

    test "a codex agent uses the model it was given" do
      {:ok, opts} = Provider.options("openai-codex", %{}, model: "gpt-5.6-terra")
      {Alloy.Provider.Codex, config} = Keyword.fetch!(opts, :provider)

      assert config.model == "gpt-5.6-terra"
    end

    test "a nil model does not erase the provider's own default" do
      # The engine passes every option it knows about and most are nil. A
      # stored nil satisfies `Keyword.get/3`, so a default written that way is
      # skipped — and the request goes to `nil` for its model and its URL.
      {:ok, opts} = Provider.options("zai", %{api_key: "k"}, model: nil, base_url: nil)
      {Alloy.Provider.OpenAICompat, config} = Keyword.fetch!(opts, :provider)

      assert config.model
      assert config.api_url =~ "z.ai"
    end
  end
end
