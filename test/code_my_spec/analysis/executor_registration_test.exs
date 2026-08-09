defmodule CodeMySpec.Analysis.ExecutorRegistrationTest do
  @moduledoc """
  Who is allowed to hold the executor registration for a working copy.

  The registration exists so two `mix test` runs never share one `_build`, and
  it is keyed on `harness_id` — which *is* the working copy, read from a file
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
    harness_id = "harness-#{System.unique_integer([:positive])}"
    {:ok, harness_id: harness_id}
  end

  # A stand-in for the channel process: it holds the registration and stays up
  # until told otherwise, exactly as an orphaned channel does.
  defp holder(harness_id, instance) do
    test = self()

    pid =
      spawn(fn ->
        result = Analysis.register_executor(harness_id, instance)
        send(test, {:registered, self(), result})
        receive do: (:never -> :ok)
      end)

    assert_receive {:registered, ^pid, :ok}, 1_000
    pid
  end

  test "the same instance takes its own registration back", %{harness_id: harness_id} do
    ghost = holder(harness_id, "boxy:4242")

    assert Analysis.register_executor(harness_id, "boxy:4242") == :ok,
           "this is the harness reconnecting, and the entry it collided with was " <>
             "its own — refusing it is a deadlock nothing ever breaks"

    refute Process.alive?(ghost),
           "the orphaned channel has to go, or the registry still points at it"

    assert [{self_pid, "boxy:4242"}] = Registry.lookup(Analysis.HarnessRegistry, harness_id)
    assert self_pid == self()
  end

  test "a different instance is still refused", %{harness_id: harness_id} do
    incumbent = holder(harness_id, "boxy:4242")

    assert {:error, {:already_registered, ^incumbent}} =
             Analysis.register_executor(harness_id, "boxy:9999"),
           "a second live harness on one `_build` is the case the lock is for"

    assert Process.alive?(incumbent)
  end

  test "an unknown instance is refused rather than guessed", %{harness_id: harness_id} do
    incumbent = holder(harness_id, "boxy:4242")

    assert {:error, {:already_registered, ^incumbent}} =
             Analysis.register_executor(harness_id, nil)

    assert Process.alive?(incumbent)
  end

  test "an unheld working copy registers straight away", %{harness_id: harness_id} do
    assert Analysis.register_executor(harness_id, "boxy:4242") == :ok
  end
end
