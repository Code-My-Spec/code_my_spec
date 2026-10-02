defmodule CodeMySpec.Embeddings.HetznerFlameBackendTest do
  @moduledoc """
  Every Hetzner-reaching call is injected (`:ensure_box` / `:start_runner` /
  `:stop_runner`), the same reason `CodeMySpec.Provisioning.BuilderTest`
  injects its own closures: this stays a unit test, and it is also the only
  option here — this module cannot reference
  `CodeMySpec.Provisioning.BurstBox` at all without a boundary violation (see
  the module's own moduledoc).

  `remote_spawn_monitor/2`'s success path and `system_shutdown/0` are not
  exercised: the first needs a second, actually-connected distributed node,
  and the second calls `System.stop/0`, which would end this test run. Both
  are a straight line to `FLAME.FlyBackend`'s own proven shape
  (`Node.spawn_monitor/2,4`, `System.stop/0`) — what is worth proving here is
  this module's *own* logic layered around them: config validation, the
  `FLAME.Parent` encoding, and the boot/timeout/ensure-failure paths through
  `remote_boot/1`.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Embeddings.HetznerFlameBackend

  defp server(id \\ 7), do: %{"id" => id, "name" => "burst-platform"}

  defp recording_stop(owner) do
    fn server, runner_name ->
      send(owner, {:stopped, server, runner_name})
      :ok
    end
  end

  defp base_opts(overrides \\ []) do
    Keyword.merge(
      [
        box_name: "burst-platform",
        ensure_box: fn _name -> {:ok, server()} end,
        start_runner: fn _server, _runner_name, _env -> :ok end,
        stop_runner: fn _server, _runner_name -> :ok end
      ],
      overrides
    )
  end

  describe "init/1 — validation" do
    for key <- [:box_name, :ensure_box, :start_runner, :stop_runner] do
      test "raises without :#{key}" do
        opts = Keyword.delete(base_opts(), unquote(key))

        assert_raise ArgumentError, ~r/missing :#{unquote(key)}/, fn ->
          HetznerFlameBackend.init(opts)
        end
      end
    end
  end

  describe "init/1 — state" do
    test "fills in the documented defaults" do
      assert {:ok, state} = HetznerFlameBackend.init(base_opts())

      assert state.boot_timeout == 180_000
      assert state.box_name == "burst-platform"
      assert String.starts_with?(state.runner_name, "cms-flame-")
    end

    test "an explicit option overrides the default" do
      assert {:ok, state} = HetznerFlameBackend.init(base_opts(boot_timeout: 5_000))
      assert state.boot_timeout == 5_000
    end

    test "application config and opts merge, with opts winning" do
      Application.put_env(:flame, HetznerFlameBackend, box_name: "burst-from-config", boot_timeout: 5_000)

      on_exit(fn -> Application.delete_env(:flame, HetznerFlameBackend) end)

      assert {:ok, state} = HetznerFlameBackend.init(base_opts(box_name: "burst-from-opts"))

      # opts wins over application config for a key both set.
      assert state.box_name == "burst-from-opts"
      # application config alone still reaches state for a key opts left out.
      assert state.boot_timeout == 5_000
    end

    test "every runner gets its own name, even though the box name is shared" do
      assert {:ok, a} = HetznerFlameBackend.init(base_opts())
      assert {:ok, b} = HetznerFlameBackend.init(base_opts())

      refute a.runner_name == b.runner_name
      assert a.box_name == b.box_name
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

  describe "remote_boot/1 — ensure_box failure" do
    test "is returned as-is, with no runner ever started and nothing to stop" do
      owner = self()

      opts =
        base_opts(
          ensure_box: fn _name -> {:error, :capacity_unavailable} end,
          start_runner: fn _server, _runner_name, _env ->
            flunk("a runner must never be started when the box could not be ensured")
          end,
          stop_runner: recording_stop(owner)
        )

      assert {:ok, state} = HetznerFlameBackend.init(opts)
      assert {:error, :capacity_unavailable} = HetznerFlameBackend.remote_boot(state)
      refute_received {:stopped, _, _}
    end
  end

  describe "remote_boot/1 — start_runner failure" do
    test "is returned as-is, once the box is already known" do
      owner = self()

      opts =
        base_opts(
          start_runner: fn _server, _runner_name, _env -> {:error, :no_capacity_on_box} end,
          stop_runner: recording_stop(owner)
        )

      assert {:ok, state} = HetznerFlameBackend.init(opts)
      assert {:error, :no_capacity_on_box} = HetznerFlameBackend.remote_boot(state)
      refute_received {:stopped, _, _}
    end
  end

  describe "remote_boot/1 — boot success" do
    test "ensures the box, starts a runner on it by this runner's own name, and returns the terminator pid" do
      test_pid = self()

      ensure_box = fn name ->
        send(test_pid, {:ensure_box_called, name})
        {:ok, server(99)}
      end

      start_runner = fn server, runner_name, env ->
        send(test_pid, {:start_runner_called, server, runner_name, env})
        :ok
      end

      opts = base_opts(ensure_box: ensure_box, start_runner: start_runner)
      assert {:ok, state} = HetznerFlameBackend.init(opts)

      # Deliver the remote-up message before booting: `remote_boot/1` blocks
      # in a bare `receive`, run synchronously in this test process, so the
      # message only has to be in the mailbox before that `receive` runs.
      send(self(), {state.parent_ref, {:remote_up, self()}})

      assert {:ok, pid, new_state} = HetznerFlameBackend.remote_boot(state)

      assert pid == self()
      assert new_state.server == server(99)
      assert new_state.runner_node_name == node(self())
      assert new_state.remote_terminator_pid == self()

      assert_received {:ensure_box_called, "burst-platform"}
      assert_received {:start_runner_called, %{"id" => 99}, runner_name, env}
      assert runner_name == state.runner_name
      assert env["FLAME_PARENT"] == state.env["FLAME_PARENT"]
    end
  end

  describe "remote_boot/1 — boot timeout" do
    test "stops just this runner, not the box, and returns :timeout" do
      owner = self()

      opts =
        base_opts(
          boot_timeout: 1,
          stop_runner: recording_stop(owner)
        )

      assert {:ok, state} = HetznerFlameBackend.init(opts)

      # No `{parent_ref, {:remote_up, _}}` is ever sent — this runner never
      # dials home within `boot_timeout`.
      assert {:error, :timeout} = HetznerFlameBackend.remote_boot(state)
      assert_received {:stopped, %{"id" => 7}, runner_name}
      assert runner_name == state.runner_name
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
