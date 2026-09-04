defmodule CmsHarness.DeviceTest do
  @moduledoc """
  The machine asserts who it is; the file that holds the answer is written once.

  Confirmed live on 2026-08-31: more than one harness install on a single box
  (a laptop's own dev harness alongside a separately-installed packaged
  service) each independently called `Device.announce/1` on their own
  schedule, and each treated `~/.codemyspec/device.json` as something the
  *server's reply* was free to overwrite. Two writers racing one file with no
  coordination meant the recorded id changed every few minutes, with no
  daemon holding one long enough for a channel join to still find it a moment
  later.

  These test the fix at the client's own boundary — a stub `Device.Client`
  standing in for the server, so what is under test is `CmsHarness.Device`'s
  own decision about when to write, not the server's reconciliation logic
  (covered separately in `CodeMySpec.DevicesTest`).
  """

  # Mutates node-global application env (:device_config_path, :device_client,
  # :harness_token).
  use ExUnit.Case, async: false

  alias CmsHarness.Device

  defmodule StubClient do
    @moduledoc "Answers exactly what the test tells it to, never the network."
    @behaviour CmsHarness.Device.Client

    @impl true
    def announce(device_id, _token, _attrs) do
      case Process.get(:device_test_reply) do
        nil -> {:ok, %{device_id: device_id, working_copies: %{}}}
        reply -> reply
      end
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "cms_device_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "device.json")

    previous = %{
      path: Application.get_env(:code_my_spec, :device_config_path),
      client: Application.get_env(:code_my_spec, :device_client),
      token: Application.get_env(:code_my_spec, :harness_token)
    }

    Application.put_env(:code_my_spec, :device_config_path, file)
    Application.put_env(:code_my_spec, :device_client, StubClient)
    Application.put_env(:code_my_spec, :harness_token, "stub-token")

    on_exit(fn ->
      restore(:device_config_path, previous.path)
      restore(:device_client, previous.client)
      restore(:harness_token, previous.token)
      File.rm_rf(dir)
    end)

    %{device_file: file}
  end

  # `Application.put_env(key, nil)` and the key never having been set are two
  # different states — the former still answers `get_env/3`'s own default with
  # `nil` rather than the default, which is exactly the crash `path/0` guards
  # against now. Restoring "was unset" back to "unset" rather than to `nil`
  # keeps this test from leaving that same landmine for whichever test runs
  # next.
  defp restore(key, nil), do: Application.delete_env(:code_my_spec, key)
  defp restore(key, value), do: Application.put_env(:code_my_spec, key, value)

  describe "a machine with no id yet" do
    test "mints one itself and writes it down", %{device_file: file} do
      refute File.exists?(file)

      assert {:ok, %{device_id: id}} = Device.announce()

      assert File.read!(file) =~ id,
             "the machine presented an id nobody asked it for and the file does " <>
               "not hold it — the next boot will mint another"

      assert Device.recorded_id() == id
    end

    test "the same file is reused across repeated announces", %{device_file: file} do
      {:ok, %{device_id: first}} = Device.announce()
      {:ok, %{device_id: second}} = Device.announce()

      assert first == second
      assert File.read!(file) =~ first
    end
  end

  describe "a machine that already holds an id" do
    test "presents its own id rather than asking the server for one", %{device_file: file} do
      File.write!(file, Jason.encode!(%{"device_id" => "established-id"}))

      assert {:ok, %{device_id: "established-id"}} = Device.announce()
      assert Device.recorded_id() == "established-id"
    end

    test "keeps its own id even when the server answers with a different one", %{
      device_file: file
    } do
      File.write!(file, Jason.encode!(%{"device_id" => "established-id"}))
      Process.put(:device_test_reply, {:ok, %{device_id: "a-different-id", working_copies: %{}}})

      assert {:ok, %{device_id: "a-different-id"}} = Device.announce(),
             "the reply itself is untouched — the module only decides whether to adopt it"

      assert Device.recorded_id() == "established-id",
             "the id already on file is a fact about this machine, not a question " <>
               "re-asked of the server on every announce. Adopting whatever the reply " <>
               "says is exactly the behaviour that let two daemons on one box overwrite " <>
               "each other's belief of who they were."
    end
  end

  # The half the overwrite fix did not reach. `write/1` refusing to move an id
  # closed the racing-writers story, but nothing was written at all until the
  # server answered — so a machine that could not reach the server held no id,
  # and the join payload `ChannelClient` builds from `recorded_id/0` went out
  # empty. The harness had minted an id one line earlier and thrown it away.
  #
  # Which produced the error in 3bc0f683, at a moment that reads as nonsense:
  # "This harness did not say which machine it is on", 0.2s after that same
  # daemon announced. The moduledoc's own argument settles it — the id is
  # generated locally and is not the server's to grant, so there is nothing to
  # wait for before writing it down.
  describe "a machine the server cannot be reached from" do
    setup do
      Process.put(:device_test_reply, {:error, :econnrefused})
      :ok
    end

    test "still writes down the id it minted", %{device_file: file} do
      assert {:error, :econnrefused} = Device.announce()

      assert File.exists?(file),
             "the machine minted an id, failed to announce it and discarded it. " <>
               "Its next channel join says it does not know which machine it is on, " <>
               "which is a network failure wearing an identity failure's error message."

      assert Device.recorded_id() != nil
    end

    test "presents the same id on every attempt until the server comes back" do
      {:error, _} = Device.announce()
      first = Device.recorded_id()

      # Explicitly, because `nil == nil` would pass this test on exactly the
      # bug it exists to catch.
      assert is_binary(first)

      {:error, _} = Device.announce()
      {:error, _} = Device.announce()

      assert Device.recorded_id() == first,
             "each attempt minted a fresh id and kept none. On a machine with no " <>
               "usable hardware address `fresh_id/0` falls back to a random UUID, so " <>
               "identity churned on every announce — and `WorkingCopyReporter` calls " <>
               "this repeatedly, not once at boot."
    end

    test "the id survives into the successful announce that follows", %{device_file: file} do
      {:error, _} = Device.announce()
      minted = Device.recorded_id()

      Process.delete(:device_test_reply)

      assert {:ok, %{device_id: ^minted}} = Device.announce(),
             "the machine changed its mind about who it was the moment the server " <>
               "came back, which is the same instability from the server's side as " <>
               "two daemons overwriting one file."

      assert File.read!(file) =~ minted
    end
  end

  describe "the machine fingerprint" do
    test "a freshly minted id is always UUID-shaped" do
      # `machine_fingerprint/0` is private, so exercised through its one
      # observable effect: whether or not this environment exposes a usable
      # hardware address, what a fresh machine presents has to be something
      # the `devices.id` column — a UUID — will accept.
      {:ok, %{device_id: id}} = Device.announce()
      assert {:ok, _} = Ecto.UUID.cast(id)
    end
  end
end
