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
  self-call answer with a refusal instead of propagating an exit through a
  reconcile. Narrowing that rescue would reintroduce a crash here, and nothing
  else would notice.

  It answers `:harness_self_call`, not `:harness_timeout`. The prose above had
  the discrimination — "0ms, not the 30s timeout" — while the atom collapsed
  both into `:harness_unreachable`, which reads as "no harness" and sends the
  reader to check a registration that is fine. The two failures have opposite
  fixes: this one is our own wiring, a timeout is the harness not answering.
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

    assert {:error, {:harness_self_call, details}} = Task.await(task, 2_000)
    assert details.op == "read_file"

    assert details.harness_id =~ "-inner",
           "the refusal names the working copy it was for — the whole complaint " <>
             "against the old atom was that it arrived bare"
  end

  test "an unregistered harness says so, rather than blaming the connection" do
    assert {:error, {:harness_not_registered, details}} =
             Analysis.harness_fs_request("nobody-serves-this", "read_file", %{}, 1_000)

    assert details == %{harness_id: "nobody-serves-this", op: "read_file"}
  end

  # The two arrive at the same `catch` and used to leave it as the same atom.
  # A reader who cannot tell them apart checks the harness for a fault that is
  # in this server, or restarts a harness that was never the problem.
  test "a self-call and an absent harness are not the same failure" do
    task =
      Task.async(fn ->
        Registry.register(HarnessRegistry, "distinct-inner", :test)
        Analysis.harness_fs_request("distinct-inner", "read_file", %{}, 1_000)
      end)

    assert {:error, {self_tag, _}} = Task.await(task, 2_000)
    assert {:error, {absent_tag, _}} = Analysis.harness_fs_request("nobody", "read_file", %{}, 1_000)

    refute self_tag == absent_tag
  end
end
