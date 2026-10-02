defmodule CodeMySpec.Embeddings.HetznerFlameBackendTest do
  @moduledoc """
  Every Hetzner call is injected (`:create_server` / `:destroy_server`), the
  same reason `CodeMySpec.Provisioning.BuilderTest` injects them: this stays
  a unit test, and it is also the only option here — this module cannot
  reference `CodeMySpec.Provisioning.Hetzner` at all without a boundary
  violation (see the module's own moduledoc).

  `remote_spawn_monitor/2`'s success path and `system_shutdown/0` are not
  exercised: the first needs a second, actually-connected distributed node,
  and the second calls `System.stop/0`, which would end this test run. Both
  are a straight line to `FLAME.FlyBackend`'s own proven shape (`Node.spawn_monitor/2,4`,
  `System.stop/0`) — what is worth proving here is this module's *own* logic
  layered around them: config validation, the `FLAME.Parent` encoding, the
  cloud-init it builds, and the boot/timeout/create-failure paths through
  `remote_boot/1`.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Embeddings.HetznerFlameBackend

  defp server(id \\ 7), do: %{"id" => id, "name" => "cms-flame-abc"}

  defp recording_destroy(owner) do
    fn id ->
      send(owner, {:destroyed, id})
      {:ok, %{}}
    end
  end

  defp base_opts(overrides \\ []) do
    Keyword.merge(
      [
        server_type: "cpx31",
        location: "fsn1",
        image: "registry.example.com/code_my_spec:abc123",
        ssh_key_ids: [1],
        create_server: fn _name, _opts -> {:ok, server()} end,
        destroy_server: fn _id -> {:ok, %{}} end
      ],
      overrides
    )
  end

  describe "init/1 — validation" do
    for key <- [:server_type, :location, :image, :create_server, :destroy_server, :ssh_key_ids] do
      test "raises without :#{key}" do
        opts = Keyword.delete(base_opts(), unquote(key))

        assert_raise ArgumentError, ~r/missing :#{unquote(key)}/, fn ->
          HetznerFlameBackend.init(opts)
        end
      end
    end

    test "an empty :ssh_key_ids list is treated as missing, same as Hetzner.create_server/3 itself" do
      assert_raise ArgumentError, ~r/missing :ssh_key_ids/, fn ->
        HetznerFlameBackend.init(base_opts(ssh_key_ids: []))
      end
    end
  end

  describe "init/1 — state" do
    test "fills in the documented defaults" do
      assert {:ok, state} = HetznerFlameBackend.init(base_opts())

      assert state.hetzner_image == "ubuntu-24.04"
      assert state.boot_timeout == 120_000
      assert String.starts_with?(state.runner_name, "cms-flame-")
    end

    test "an explicit option overrides the default" do
      assert {:ok, state} =
               HetznerFlameBackend.init(base_opts(hetzner_image: "cms-flame-snapshot"))

      assert state.hetzner_image == "cms-flame-snapshot"
    end

    test "application config and opts merge, with opts winning" do
      Application.put_env(:flame, HetznerFlameBackend, location: "hel1", boot_timeout: 5_000)

      on_exit(fn -> Application.delete_env(:flame, HetznerFlameBackend) end)

      assert {:ok, state} = HetznerFlameBackend.init(base_opts(location: "ash"))

      # opts wins over application config for a key both set.
      assert state.location == "ash"
      # application config alone still reaches state for a key opts left out.
      assert state.boot_timeout == 5_000
    end

    test "every runner gets its own name" do
      assert {:ok, a} = HetznerFlameBackend.init(base_opts())
      assert {:ok, b} = HetznerFlameBackend.init(base_opts())

      refute a.runner_name == b.runner_name
    end

    test "env always carries FLAME_PARENT and PHX_SERVER=false, with a caller's own env merged in" do
      assert {:ok, state} = HetznerFlameBackend.init(base_opts(env: %{"FOO" => "bar"}))

      assert state.env["PHX_SERVER"] == "false"
      assert is_binary(state.env["FLAME_PARENT"])
      assert state.env["FOO"] == "bar"

      # The encoded parent is exactly what `FLAME.Parent.get/0` expects to
      # decode on the remote side — proven by decoding it the same way.
      decoded =
        state.env["FLAME_PARENT"]
        |> Base.decode64!()
        |> :erlang.binary_to_term()

      assert decoded.backend == HetznerFlameBackend
      assert decoded.node_base == state.runner_name
      assert decoded.host_env == "CMS_FLAME_RUNNER_IP"
    end

    test "an unknown option is refused rather than silently ignored" do
      assert_raise ArgumentError, ~r/unknown keys \[:not_a_real_option\]/, fn ->
        HetznerFlameBackend.init(base_opts(not_a_real_option: true))
      end
    end
  end

  describe "cloud_init/1" do
    test "runs the configured image with the computed env, and logs in to nothing by default" do
      assert {:ok, state} = HetznerFlameBackend.init(base_opts(env: %{"EXTRA" => "1"}))

      script = HetznerFlameBackend.cloud_init(state)

      assert script =~ "docker run -d --name " <> "'" <> state.runner_name <> "'"
      assert script =~ "'registry.example.com/code_my_spec:abc123'"
      assert script =~ "-e 'EXTRA=1'"
      assert script =~ "-e 'PHX_SERVER=false'"
      refute script =~ "docker login"
    end

    test "a registry credential adds a docker login line ahead of the run, and is shell-safe" do
      assert {:ok, state} =
               HetznerFlameBackend.init(
                 base_opts(registry_auth: %{username: "cms", password: "it's a secret"})
               )

      script = HetznerFlameBackend.cloud_init(state)
      lines = String.split(script, "\n")

      login_at = Enum.find_index(lines, &String.contains?(&1, "docker login"))
      run_at = Enum.find_index(lines, &String.contains?(&1, "docker run"))

      assert login_at && run_at && login_at < run_at
      assert Enum.at(lines, login_at) =~ "registry.example.com"
      # The single quote inside the password survives shell-quoting rather
      # than breaking out of the quoted string.
      assert Enum.at(lines, login_at) =~ "'it'\\''s a secret'"
    end
  end

  describe "remote_boot/1 — create failure" do
    test "a create failure is returned as-is, with nothing to destroy" do
      owner = self()

      opts =
        base_opts(
          create_server: fn _name, _opts -> {:error, :capacity_unavailable} end,
          destroy_server: fn id -> send(owner, {:destroyed, id}) end
        )

      assert {:ok, state} = HetznerFlameBackend.init(opts)
      assert {:error, :capacity_unavailable} = HetznerFlameBackend.remote_boot(state)
      refute_received {:destroyed, _}
    end

    test "the created server's own fields reach create_server as a Hetzner create_server/3 payload" do
      test_pid = self()

      create_server = fn name, create_opts ->
        send(test_pid, {:create_called, name, create_opts})
        {:ok, server()}
      end

      opts =
        base_opts(
          server_type: "cpx41",
          location: "ash",
          hetzner_image: "cms-flame-snapshot",
          ssh_key_ids: [9],
          network_ids: [3],
          labels: %{"team" => "platform"},
          create_server: create_server
        )

      assert {:ok, state} = HetznerFlameBackend.init(opts)

      # Deliver the remote-up message before booting: `remote_boot/1` blocks
      # in a bare `receive`, run synchronously in this test process, so the
      # message only has to be in the mailbox before that `receive` runs.
      send(self(), {state.parent_ref, {:remote_up, self()}})

      assert {:ok, _pid, _new_state} = HetznerFlameBackend.remote_boot(state)
      assert_received {:create_called, name, create_opts}

      assert name == state.runner_name
      assert create_opts[:server_type] == "cpx41"
      assert create_opts[:location] == "ash"
      assert create_opts[:image] == "cms-flame-snapshot"
      assert create_opts[:ssh_key_ids] == [9]
      assert create_opts[:network_ids] == [3]
      assert create_opts[:labels] == %{"team" => "platform", "cms-flame-role" => "embed"}
      assert is_binary(create_opts[:user_data])
    end
  end

  describe "remote_boot/1 — boot success" do
    test "returns the terminator pid and records the runner id and node" do
      opts = base_opts(create_server: fn _name, _opts -> {:ok, server(99)} end)
      assert {:ok, state} = HetznerFlameBackend.init(opts)

      send(self(), {state.parent_ref, {:remote_up, self()}})

      assert {:ok, pid, new_state} = HetznerFlameBackend.remote_boot(state)

      assert pid == self()
      assert new_state.runner_id == 99
      assert new_state.runner_node_name == node(self())
      assert new_state.remote_terminator_pid == self()
    end

    test "reads the server id through Hetzner's {\"server\" => ...} create envelope too" do
      opts = base_opts(create_server: fn _name, _opts -> {:ok, %{"server" => server(5)}} end)
      assert {:ok, state} = HetznerFlameBackend.init(opts)

      send(self(), {state.parent_ref, {:remote_up, self()}})

      assert {:ok, _pid, new_state} = HetznerFlameBackend.remote_boot(state)
      assert new_state.runner_id == 5
    end
  end

  describe "remote_boot/1 — boot timeout" do
    test "destroys the box it just created and returns :timeout, rather than leaving it running" do
      owner = self()

      opts =
        base_opts(
          boot_timeout: 1,
          create_server: fn _name, _opts -> {:ok, server(42)} end,
          destroy_server: recording_destroy(owner)
        )

      assert {:ok, state} = HetznerFlameBackend.init(opts)

      # No `{parent_ref, {:remote_up, _}}` is ever sent — this box never
      # dials home within `boot_timeout`.
      assert {:error, :timeout} = HetznerFlameBackend.remote_boot(state)
      assert_received {:destroyed, 42}
    end
  end

  describe "remote_spawn_monitor/2 — input validation" do
    test "refuses anything that is not a 0-arity function or {mod, fun, args}" do
      state = %HetznerFlameBackend{runner_node_name: node()}

      assert_raise ArgumentError, ~r/expected a null arity function/, fn ->
        HetznerFlameBackend.remote_spawn_monitor(state, "not a function")
      end
    end
  end
end
