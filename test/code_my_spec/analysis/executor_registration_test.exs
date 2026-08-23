defmodule CodeMySpec.Analysis.ExecutorRegistrationTest do
  @moduledoc """
  Who is allowed to hold the executor registration for a working copy.

  The registration exists so two `mix test` runs never share one `_build`, and
  it is keyed on `working_copy_id` — which *is* the working copy, read from a file
  inside it. So every collision is that copy colliding with itself, and the id
  cannot say whether the joiner is a rival or the same process coming back.

  Getting that wrong is not a slow recovery. The entry only dies with the
  channel, and the channel only dies with its socket, so a harness whose
  client-side channel went while the socket stayed open waits behind its own
  ghost forever — every hook refusing `:not_connected` at a server answering
  200. It took killing the harness process to clear.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Analysis

  setup do
    # Same registry the harness channel uses; the app already starts it.
    working_copy_id = "harness-#{System.unique_integer([:positive])}"
    {:ok, working_copy_id: working_copy_id}
  end

  # A stand-in for the channel process: it holds the registration and stays up
  # until told otherwise, exactly as an orphaned channel does.
  defp holder(working_copy_id, instance, root \\ nil) do
    test = self()

    pid =
      spawn(fn ->
        result = Analysis.register_executor(working_copy_id, instance, root)
        send(test, {:registered, self(), result})
        receive do: (:never -> :ok)
      end)

    assert_receive {:registered, ^pid, :ok}, 1_000
    pid
  end

  test "the same instance takes its own registration back", %{working_copy_id: working_copy_id} do
    ghost = holder(working_copy_id, "boxy:4242")

    assert Analysis.register_executor(working_copy_id, "boxy:4242") == :ok,
           "this is the harness reconnecting, and the entry it collided with was " <>
             "its own — refusing it is a deadlock nothing ever breaks"

    refute Process.alive?(ghost),
           "the orphaned channel has to go, or the registry still points at it"

    assert [{self_pid, {"boxy:4242", nil}}] =
             Registry.lookup(Analysis.HarnessRegistry, working_copy_id)

    assert self_pid == self()
  end

  # The 2026-08-20 outage. `take_over/4` matched on the instance alone, and one
  # daemon serves several working copies — so a join for checkout B, arriving
  # from the same OS process as checkout A's channel, looked like A reconnecting
  # and killed it. A rejoined and killed B back: 1078 evictions at roughly one a
  # second, every stop hook refused, until the process was restarted.
  #
  # It needed the ids to have collapsed first (`HarnessConfig.read/1` used to let
  # `CMS_HARNESS_ID` beat the file), which is fixed separately. This is the guard
  # that makes the next identity bug a refusal naming both roots instead of a
  # loop diagnosed from the outside.
  test "one process holding two different roots is refused, not evicted", %{
    working_copy_id: working_copy_id
  } do
    incumbent = holder(working_copy_id, "boxy:4242", "/checkouts/a")

    assert {:error, {:id_collision, ^incumbent, "/checkouts/a"}} =
             Analysis.register_executor(working_copy_id, "boxy:4242", "/checkouts/b"),
           "same instance is 'the same OS process', not 'the same working copy'"

    assert Process.alive?(incumbent),
           "the sibling's channel must survive — killing it is the loop"
  end

  test "the same process reconnecting to the same root still takes it back", %{
    working_copy_id: working_copy_id
  } do
    ghost = holder(working_copy_id, "boxy:4242", "/checkouts/a")

    assert Analysis.register_executor(working_copy_id, "boxy:4242", "/checkouts/a") == :ok,
           "adding the root must not break the ghost-entry recovery the instance " <>
             "match exists for — that deadlock cleared only by killing the harness"

    refute Process.alive?(ghost)
  end

  test "a different instance is still refused", %{working_copy_id: working_copy_id} do
    incumbent = holder(working_copy_id, "boxy:4242")

    assert {:error, {:already_registered, ^incumbent}} =
             Analysis.register_executor(working_copy_id, "boxy:9999"),
           "a second live harness on one `_build` is the case the lock is for"

    assert Process.alive?(incumbent)
  end

  test "an unknown instance is refused rather than guessed", %{working_copy_id: working_copy_id} do
    incumbent = holder(working_copy_id, "boxy:4242")

    assert {:error, {:already_registered, ^incumbent}} =
             Analysis.register_executor(working_copy_id, nil)

    assert Process.alive?(incumbent)
  end

  test "an unheld working copy registers straight away", %{working_copy_id: working_copy_id} do
    assert Analysis.register_executor(working_copy_id, "boxy:4242") == :ok
  end
end
