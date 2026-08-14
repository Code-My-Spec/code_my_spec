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
  use ExUnit.Case, async: true

  alias CodeMySpec.BootVersion

  setup do
    # `contract_changed?/2` reads the root out of the same persistent term
    # `capture/1` writes, so capturing here is what points it at this checkout.
    #
    # Erased afterwards because the term is node-global and outlives the test.
    # Left set, `drift/0` stops returning `:none` for everything downstream and
    # starts shelling out `git rev-parse --short HEAD` — which under ExCliVcr is
    # an unrecorded command, so `hook_decision_test:359` fails with
    # `CassetteNotFoundError` whenever the seed happens to order this file first.
    # Intermittent, and it reads as a missing cassette rather than as a test
    # that left the node dirty.
    BootVersion.capture(File.cwd!())
    on_exit(fn -> :persistent_term.erase({BootVersion, :boot}) end)
    :ok
  end

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
