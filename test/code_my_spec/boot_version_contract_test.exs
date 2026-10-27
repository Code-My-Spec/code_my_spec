defmodule CodeMySpec.BootVersionContractTest do
  @moduledoc """
  Whether the drifted range touched the code that decides if a harness and a
  server can talk.

  `drift/0` says only that the checkout moved, which is true after almost every
  commit of an active session. The message built on it therefore said "if that
  range touched the harness or the channel contract, restart it" — a condition
  handed to the reader. The reader who acted on it ran

      git diff --stat 0dd3fc43..8a18a296 -- lib/cms_harness lib/code_my_spec_web/channels

  by hand before believing it, and called that "diagnosis to confirmation in one
  command". `contract_changed?/2` is that command, so the message states a fact.

  Driven against this repository's real history rather than a fixture, because
  the thing under test is a `git diff` and a fixture repo would prove only that
  the arguments were spelled correctly.
  """
  # capture/1 changes node-global persistent_term read by promotion tests.
  use ExUnit.Case, async: false

  alias CodeMySpec.BootVersion

  @key {BootVersion, :boot}

  setup do
    # `contract_changed?/2` reads the root out of the same persistent term
    # `capture/1` writes, so capturing here is what points it at this checkout.
    #
    # Restored, not erased: the application captures it at boot. This module
    # runs synchronously because async promotion tests read the same node-global
    # value; restoring nil beside one changed its deployment plan (2026-10-26).
    previous = :persistent_term.get(@key, nil)
    BootVersion.capture(File.cwd!())
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore(nil), do: :persistent_term.erase(@key)
  defp restore(previous), do: :persistent_term.put(@key, previous)

  describe "contract_changed?/2" do
    test "says true for a range that changed the harness" do
      # `35d7941a` is "A harness with no credential does not start…", which
      # edits lib/cms_harness/hook_decision.ex.
      assert BootVersion.contract_changed?("35d7941a~1", "35d7941a") == true
    end

    test "says false for a range that did not" do
      # `c014a2df` is "An unrecorded latch says what records it" — requirements
      # and its test, nothing under lib/cms_harness or the channels.
      assert BootVersion.contract_changed?("c014a2df~1", "c014a2df") == false
    end

    # The distinction that matters most: a wrong "nothing changed" sends a
    # genuinely stale harness off to look at its network, so an unreadable range
    # has to answer :unknown rather than default to either verdict.
    test "says unknown when the range cannot be read" do
      assert BootVersion.contract_changed?("0000000", "1111111") == :unknown
    end
  end
end
