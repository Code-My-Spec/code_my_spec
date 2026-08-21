defmodule CodeMySpec.Analysis.RequestRescanTest do
  @moduledoc """
  Asking the harness holding a working copy to rescan it.

  The server cannot walk a checkout on another machine —
  `Environments.Harness.stream_files/3` refuses on purpose, because bulk reads
  are the manifest's job rather than a round trip per file. So `sync_project`
  had nothing to do on a harness-held project and said so: "the graph is already
  current, there is no sync step to run."

  True right up until it is not. The harness watches the working copy, but
  watching stops while it is disconnected — it logs "File changes are not being
  recorded" — and only a reconnect starts a fresh full scan. An agent with
  reason to think the graph was stale was told there was nothing to do about it,
  and the version that did try surfaced
  `{:cannot_scan, :not_supported_on_harness}`, which reads as a broken tool
  (b10c4b46).

  Fire-and-forget on purpose, the same shape as `run_analysis`: this side owns
  the record, that side owns the disk, and a scan of a few thousand files takes
  seconds. What comes back is a manifest on the ordinary `observations` path,
  so there is no second result channel to keep in step.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Analysis
  alias CodeMySpec.Users.Scope

  defp scope(harness_id), do: %Scope{active_harness_id: harness_id}

  # A stand-in for the channel process, which is what the registry holds.
  defp registered_channel(harness_id) do
    test = self()

    pid =
      spawn(fn ->
        :ok = Analysis.register_executor(harness_id, "test:#{System.unique_integer()}")
        send(test, {:registered, self()})

        receive do
          message -> send(test, {:channel_got, message})
        end
      end)

    assert_receive {:registered, ^pid}, 1_000
    pid
  end

  test "a registered harness is sent the rescan" do
    harness_id = "harness-#{System.unique_integer([:positive])}"
    _pid = registered_channel(harness_id)

    assert Analysis.request_rescan(scope(harness_id)) == :ok

    assert_receive {:channel_got, :rescan}, 1_000
  end

  test "nothing registered under that id is named as such, not as a dead harness" do
    harness_id = "harness-#{System.unique_integer([:positive])}"

    assert {:error, {:harness_not_registered, details}} =
             Analysis.request_rescan(scope(harness_id))

    assert details.harness_id == harness_id,
           "the caller renders this for an agent, and a tag with no id sends the " <>
             "reader looking at the wrong working copy"
  end

  # A scope with no harness has no working copy to ask. Distinct from a harness
  # that exists and cannot be reached, and the callers render them differently.
  test "a scope with no harness is refused without a registry lookup" do
    assert {:error, {:harness_not_registered, %{harness_id: nil}}} =
             Analysis.request_rescan(scope(nil))
  end
end
