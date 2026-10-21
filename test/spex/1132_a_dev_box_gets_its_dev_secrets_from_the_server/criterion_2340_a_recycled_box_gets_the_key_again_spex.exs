defmodule CodeMySpecSpex.Story1132.Criterion2340Spex do
  @moduledoc """
  Story 1132 -- A dev box gets its dev secrets from the server.
  Criterion 2340 -- A recycled box gets the key again.

  "Recycled" means the box itself, and whatever held the key in memory, is
  gone. What proves the server did not quietly decide "already told this
  one" is the same working copy's channel being left and rejoined, with the
  key handed over again on the second join -- not a fixture standing in for
  a restart, the real lease-then-release the channel's own moduledoc
  describes ("the channel is the lease").

  Leaving the channel is driven through the real `leave/1`, not a direct
  call to the `terminate/2` callback: the channel is a real linked process,
  and only actually stopping it fires whatever releases the lease on its
  exit. The test traps exits first so that exit does not take the test down
  with it, the same shape `harness_project_channel_test.exs`'s own
  "the channel's lifetime is the lease" describe block uses.
  """

  use CodeMySpecSpex.Case

  import Phoenix.ChannelTest

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    Process.flag(:trap_exit, true)
    :ok
  end

  spex "Nothing withholds the key from a box joining the same checkout again",
    criterion: 2340 do
    scenario "'cloud-1' was recycled and its harness restarted" do
      given_ "'cloud-1' already connected once and received its key", context do
        Fixtures.put_project_secret(context.scope, "age_private_key_dev", "AGE-SECRET-KEY-1DEV")

        topic = "harness_project:#{context.scope.active_project_id}"
        device = Fixtures.device_fixture(context.scope)

        {:ok, first_reply, first_socket} =
          UserSocket
          |> socket("harness_test", %{scope: context.scope})
          |> subscribe_and_join(HarnessProjectChannel, topic, %{
            "label" => "cloud-1",
            "harness_id" => context.scope.active_working_copy_id,
            "device" => %{"id" => device.id}
          })

        assert first_reply.sops_age_keys != [],
               "the first join never received a key, so a second join cannot prove anything " <>
                 "about recycling"

        down_ref = Process.monitor(first_socket.channel_pid)
        leave(first_socket)
        assert_receive {:DOWN, ^down_ref, :process, _, _}, 2_000

        {:ok,
         Map.merge(context, %{
           topic: topic,
           device: device,
           working_copy_id: first_reply.working_copy_id
         })}
      end

      when_ "it reconnects, as a recycled box with nothing carried over in memory", context do
        # The :DOWN above confirms the first channel process has fully exited
        # (and so released its lease) before this runs -- not a race this
        # needs to retry past.
        {:ok, reply, _socket} =
          UserSocket
          |> socket("harness_test_2", %{scope: context.scope})
          |> subscribe_and_join(HarnessProjectChannel, context.topic, %{
            "label" => "cloud-1",
            "harness_id" => context.working_copy_id,
            "device" => %{"id" => context.device.id}
          })

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it receives the key again, since nothing kept it", context do
        assert context.reply.sops_age_keys != [],
               "the recycled box's second join received no key at all, as if the server had " <>
                 "decided it was already given once"

        {:ok, context}
      end
    end
  end
end
