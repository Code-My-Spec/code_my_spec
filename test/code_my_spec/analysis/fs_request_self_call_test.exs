defmodule CodeMySpec.Analysis.FsRequestSelfCallTest do
  @moduledoc """
  The fs proxy refuses to call the process it is running in.

  `harness_fs_request/4` reaches the harness by `GenServer.call`ing its channel
  process, which answers out of band — it pushes `fs_request` to the device and
  replies when `fs_result` arrives. That works precisely because the caller is
  someone else.

  It is not always someone else. `accept_manifest/2` reconciles in a
  `Task.Supervisor` process normally, but inline in the channel process under
  `analysis_mode: :inline` — the test environment. A reconcile there that
  reaches for a file calls the channel from inside the channel.

  That does not hang, which is worth writing down because it looks like it
  should. OTP detects the self-call and exits immediately with
  `{:calling_self, …}` — measured at 0ms, not the 30s timeout — and
  `harness_fs_request/4`'s `catch :exit` turns it into the same refusal any
  other unreachable harness gets.

  So the property under test is ours, not OTP's: the `catch` is what makes a
  self-call answer `{:error, :harness_unreachable}` instead of propagating an
  exit through a reconcile. Narrowing that rescue would reintroduce a crash
  here, and nothing else would notice.
  """

  use ExUnit.Case, async: false

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.HarnessRegistry

  setup do
    id = "self-call-#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.register(HarnessRegistry, id, :test)
    %{harness_id: id}
  end

  test "a request to the calling process is refused rather than deadlocking", ctx do
    # Registered as this process, so the lookup resolves to `self()`. Without
    # the guard this call blocks for the full timeout and returns nothing
    # useful; the assertion is that it comes back at all.
    task =
      Task.async(fn ->
        Registry.register(HarnessRegistry, ctx.harness_id <> "-inner", :test)
        Analysis.harness_fs_request(ctx.harness_id <> "-inner", "read_file", %{}, 1_000)
      end)

    assert {:error, :harness_unreachable} = Task.await(task, 2_000)
  end

  test "an unregistered harness is still unreachable" do
    assert {:error, :harness_unreachable} =
             Analysis.harness_fs_request("nobody-serves-this", "read_file", %{}, 1_000)
  end
end
