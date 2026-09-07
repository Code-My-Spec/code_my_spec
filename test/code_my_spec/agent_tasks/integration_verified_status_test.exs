defmodule CodeMySpec.AgentTasks.IntegrationVerifiedStatusTest do
  @moduledoc """
  Whether an integration counts as verified.

  The check was `String.contains?(String.downcase(content), "verified")` over
  the whole document. "unverified" contains "verified", so an integration
  explicitly marked unverified satisfied the gate — as did one whose prose
  merely mentioned the word. A gate that reports satisfied when it is not is the
  worst failure available to a gate, because nothing about it looks wrong.

  Found while reading `77aa93b0`, which asks for this status to move into a
  table. That is still the right shape; this is the correctness bug the parsing
  was hiding in the meantime.

  Driven by writing the spec, syncing it, and asking `evaluate/2` — the whole
  path, rather than a copy of the regex. The parse now happens at sync, so a
  test that reached only `evaluate/2` would no longer touch it.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.QaIntegrationPlan
  alias CodeMySpec.Environments
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Support.InMemoryEnvironment

  # The index is a file beside the directory, not inside it — anything inside is
  # globbed as a spec and checked for its own Verify Script.
  @index ".code_my_spec/integrations.md"
  @spec_path ".code_my_spec/integrations/acme.md"
  @script "bin/verify_acme.sh"

  setup do
    {:ok, env} = InMemoryEnvironment.create()
    on_exit(fn -> InMemoryEnvironment.destroy(env) end)

    scope = %{full_scope_fixture() | environment: env}
    %{scope: scope, env: env}
  end

  # Written *and synced*, because the sync is where the status is now read.
  #
  # `evaluate/2` used to parse this itself, against the environment, on every
  # graph computation — a `GenServer.call` to the harness with a 35-second limit
  # for a project served by one. `Scanner.validate_integration/1` parses it
  # once, when the file changes, and `evaluate/2` reads the verdict off the row.
  #
  # So the sync is not setup here, it is half the path under test: the same
  # regex reached through the surface that actually runs it.
  defp seed!(scope, env, spec_body) do
    :ok = Environments.write_file(env, @index, "# Integrations\n\n- acme\n")
    :ok = Environments.write_file(env, @script, "#!/bin/sh\n")
    :ok = Environments.write_file(env, @spec_path, spec_body)

    {:ok, _} = FileSync.sync(scope, embed: false)
  end

  defp spec_with(status) do
    """
    # Acme

    ## Verify Script

    `#{@script}`

    ## Status

    #{status}
    """
  end

  defp verified?(scope, env, status) do
    seed!(scope, env, spec_with(status))
    match?({:ok, _}, QaIntegrationPlan.evaluate(scope, %{}))
  end

  describe "a verified integration" do
    test "passes", %{scope: scope, env: env} do
      assert verified?(scope, env, "verified")
    end

    test "passes with surrounding whitespace or a trailing note", %{scope: scope, env: env} do
      assert verified?(scope, env, "  verified  ")
      assert verified?(scope, env, "verified — 2026-08-15 against the live account")
    end
  end

  describe "an integration that is not verified" do
    # The bug. "unverified" contains "verified", so this passed.
    test "does not pass merely by containing the word", %{scope: scope, env: env} do
      refute verified?(scope, env, "unverified")
    end

    test "does not pass when it says so in other words", %{scope: scope, env: env} do
      refute verified?(scope, env, "not verified")
      refute verified?(scope, env, "pending verification")
      refute verified?(scope, env, "pending")
    end

    test "does not pass on an empty status", %{scope: scope, env: env} do
      refute verified?(scope, env, "")
    end
  end

  # A spec whose prose explains what verification means, with a status saying it
  # has not happened. The old check read the whole file, so the prose answered a
  # question the status section was answering differently.
  test "the word elsewhere in the document does not stand in for the status",
       %{scope: scope, env: env} do
    seed!(scope, env, """
    # Acme

    Once verified, this integration is safe to rely on. A verified integration
    has been checked against the live account.

    ## Verify Script

    `#{@script}`

    ## Status

    pending
    """)

    refute match?({:ok, _}, QaIntegrationPlan.evaluate(scope, %{}))
  end
end
