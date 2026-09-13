defmodule CodeMySpec.Analysis.FsRequestChannelDeathTest do
  @moduledoc """
  A channel that dies mid-request is not a channel that hung.

  `harness_fs_request/4` reaches the harness by `GenServer.call`ing its channel
  process. Two things can go wrong after the request is accepted, and they look
  identical from the caller's side — both arrive as an exit — while wanting
  opposite responses:

    * the channel takes the request and never answers. Wait longer, or find out
      what the harness is stuck on.
    * the channel *dies* before answering. Waiting longer cannot help; the
      question is what took the process down.

  OTP hands us the discrimination for free — `GenServer.call/3` exits
  `{:timeout, …}` on the limit and with the callee's own reason when it dies
  first — and the `catch :exit` clause used to fold both into
  `:harness_timeout`. That is the same collapse `FsRequestSelfCallTest` was
  written about, one level finer: an atom that names one failure being applied
  to another whose fix has nothing in common with it.

  It is not hypothetical, and the case that matters is the one where the death
  means *success*. A `promotion_restart` asks the running application to
  restart; the restart drains the endpoint; the endpoint is what was carrying
  the reply. So the happy path ends with the channel dying about a second in.
  Labelled a timeout, that was published as

      did not complete after 3019ms (limit 605000ms) … the harness is
      registered, so this is not a connection problem — it accepted the
      request and did not answer

  where the two numbers cannot both describe a timeout, the connection going
  away is exactly what happened, and `[Promotion] restart FAILED` followed at
  error level while :4000 was up and serving the new revision. Six of them in
  one deploy.

  So: the tags are distinct, the death carries its exit reason, and the shape a
  restart produces is still recognised by the predicate that decides not to
  retry it.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Promotion
  alias CodeMySpec.Promotion.Runner

  # Unlinked, so its exit is the subject of the test rather than the end of it,
  # and it registers itself so the registry entry dies when it does — which is
  # what makes this the real shape rather than a mocked one.
  defp a_channel_that_dies_with(reason) do
    id = "dies-#{System.unique_integer([:positive])}"
    test = self()

    spawn(fn ->
      {:ok, _} = Registry.register(HarnessRegistry, id, :test)
      send(test, {:registered, id})

      receive do
        {:"$gen_call", _from, {:fs_request, _op, _payload}} -> exit(reason)
      end
    end)

    assert_receive {:registered, ^id}, 2_000
    id
  end

  defp a_channel_that_never_answers do
    id = "silent-#{System.unique_integer([:positive])}"
    test = self()

    spawn(fn ->
      {:ok, _} = Registry.register(HarnessRegistry, id, :test)
      send(test, {:registered, id})
      Process.sleep(:infinity)
    end)

    assert_receive {:registered, ^id}, 2_000
    id
  end

  test "a channel that goes down says so, and carries what took it down" do
    id = a_channel_that_dies_with({:shutdown, :draining})

    assert {:error, {:harness_gone, details}} =
             Analysis.harness_fs_request(id, "promotion_restart", %{}, 600_000)

    assert details.down == {:shutdown, :draining},
           "the exit reason is the one thing the reader cannot recover afterwards — " <>
             "the process is gone and its reason went with it"

    assert details.op == "promotion_restart"
    assert details.working_copy_id == id
  end

  test "it does not print a limit it never reached" do
    id = a_channel_that_dies_with({:shutdown, :draining})

    assert {:error, {:harness_gone, details}} =
             Analysis.harness_fs_request(id, "promotion_restart", %{}, 600_000)

    assert details.elapsed_ms < 5_000

    refute Map.has_key?(details, :limit_ms), """
    A limit is what you compare against when something ran out of time. Printed
    beside a death it is what made the original line read as a timeout that had
    not happened: "after 3019ms (limit 605000ms)" invited every reader to go
    looking for something slow.
    """
  end

  @tag timeout: 30_000
  test "a channel that genuinely hangs is still a timeout" do
    id = a_channel_that_never_answers()

    # The floor is `timeout + 5_000`, so this is as short as a real timeout gets.
    assert {:error, {:harness_timeout, details}} =
             Analysis.harness_fs_request(id, "read_file", %{}, 0)

    assert details.limit_ms == 5_000,
           "a timeout is the one failure where the limit belongs in the details"
  end

  test "the two are not reported as the same failure" do
    dead = a_channel_that_dies_with({:shutdown, :draining})

    assert {:error, {gone_tag, _}} = Analysis.harness_fs_request(dead, "read_file", %{}, 600_000)

    refute gone_tag == :harness_timeout, """
    These collapsed into one atom and the collapse was invisible, because each
    reading is plausible on its own. A reader told "timeout" waits; the process
    they are waiting for is already gone.
    """
  end

  describe "the promotion chain this broke" do
    # The bug was never in the predicate — `restart_acknowledgement_lost?/1`
    # had the rule and the tests for it. It was that the reason reaching the
    # predicate is a *string*, built by `Runner.decode/1` out of whatever tag
    # this module chose. Renaming the tag is therefore a change to a contract
    # nothing else names out loud, which is worth one test.
    test "a restart whose channel died is still recognised as a lost acknowledgement" do
      id = a_channel_that_dies_with({:shutdown, :draining})

      scope = %CodeMySpec.Users.Scope{
        environment: %CodeMySpec.Environments.Environment{type: :harness}
      }

      assert {:error, reason} = Runner.restart(scope, "/anywhere", id)

      assert Promotion.restart_acknowledgement_lost?(reason), """
      A restart that worked has to keep reading as "merged, restart
      unconfirmed" rather than as a failure. When it does not, the agent is
      told to promote again — and each retry restarts the shared dev server
      every other working copy on this box is using. Got: #{inspect(reason)}
      """
    end
  end
end
