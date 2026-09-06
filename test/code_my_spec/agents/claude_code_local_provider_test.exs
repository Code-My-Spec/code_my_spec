defmodule CodeMySpec.Agents.ClaudeCodeLocalProviderTest do
  @moduledoc """
  `claude-code` is the one provider with no per-account credential — it runs
  on whichever `claude` CLI login already exists on the harness machine. So
  the thing worth proving is exactly the shortcut: every account reads it as
  connected, unconditionally, with no Integration involved at all.

  This is deliberately unscoped for now — see the TODO on
  `CodeMySpec.Agents.Providers.@providers` about restricting it to specific
  accounts before it is any more available than that.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Credential
  alias CodeMySpec.Agents.Providers

  setup do
    %{scope: full_scope_fixture()}
  end

  test "known to Providers, alongside the account-scoped ones" do
    assert Providers.known?("claude-code")
    assert "claude-code" in Providers.names()
  end

  test "its kind is :local, not one of Pi's two credential kinds" do
    assert Providers.kind("claude-code") == {:ok, :local}
  end

  test "Credential.fetch/2 is always {:ok, %{}} - no Integration checked", %{scope: scope} do
    assert Credential.fetch(scope, "claude-code") == {:ok, %{}}
  end

  test "Credential.source/2 is always :user - never platform-billed, never capped", %{
    scope: scope
  } do
    assert Credential.source(scope, "claude-code") == :user
  end

  test "Agents.connected_providers/1 includes it even with nothing else connected", %{
    scope: scope
  } do
    assert "claude-code" in Agents.connected_providers(scope)
  end
end
