defmodule CodeMySpec.Provisioning.BurstBoxTest do
  @moduledoc """
  Every Hetzner/SSH-reaching call is injected — `:find`/`:create`/
  `:ensure_burst_box_image` as closures, `:run` as the
  `(list() -> {String.t(), non_neg_integer()})` shape
  `Builder.Remote.ssh_runner/2` already produces — the same reason
  `CodeMySpec.Provisioning.BuilderTest` and `...BurstBox.LifecycleTest` stay
  unit tests. Nothing here reaches a real Hetzner account or a real box.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodeMySpec.Provisioning.BurstBox
  alias CodeMySpec.Provisioning.BurstBox.FlyPeering
  alias CodeMySpec.Users.Scope

  defp platform_scope, do: %Scope{}
  defp customer_scope, do: %Scope{active_project_id: Ecto.UUID.generate()}

  defp server(overrides \\ %{}) do
    Map.merge(%{"id" => 7, "name" => "burst-platform"}, overrides)
  end

  defp peer do
    %{
      private_key: "cHJpdmF0ZWtleQ==",
      address: "fdaa:1:2::3/120",
      peer_public_key: "cHVibGlja2V5",
      endpoint: "fly-gateway.example.com:51820",
      allowed_ips: "fdaa::/16"
    }
  end

  describe "ensure_box/3 — finding" do
    test "returns the box as-is when it already exists, touching neither the image nor create" do
      find = fn _scope, "burst-platform" -> {:ok, server()} end

      ensure_image = fn _scope, _arch, _opts ->
        flunk("an existing box must not build an image")
      end

      create = fn _scope, _name, _opts -> flunk("an existing box must not be created again") end

      assert {:ok, %{"id" => 7}} =
               BurstBox.ensure_box(platform_scope(), "burst-platform",
                 find: find,
                 ensure_burst_box_image: ensure_image,
                 create: create
               )
    end

    test "an error from :find other than :not_found is returned unchanged" do
      find = fn _scope, _name -> {:error, :hetzner_not_configured} end

      assert {:error, :hetzner_not_configured} =
               BurstBox.ensure_box(platform_scope(), "burst-platform", find: find)
    end
  end

  describe "ensure_box/3 — creating" do
    defp creating_opts(overrides \\ []) do
      Keyword.merge(
        [
          find: fn _scope, _name -> {:error, :not_found} end,
          ensure_burst_box_image: fn _scope, _arch, _opts -> {:ok, 555} end,
          create: fn _scope, _name, _create_opts -> {:ok, %{"server" => server()}} end
        ],
        overrides
      )
    end

    test "builds the burst-box image and creates the server from it when absent" do
      owner = self()

      create = fn _scope, name, create_opts ->
        send(owner, {:created, name, create_opts})
        {:ok, %{"server" => server()}}
      end

      assert {:ok, %{"id" => 7}} =
               BurstBox.ensure_box(
                 platform_scope(),
                 "burst-platform",
                 creating_opts(create: create)
               )

      assert_received {:created, "burst-platform", create_opts}
      assert create_opts[:image] == 555
      assert create_opts[:server_type] == "cax11"
      assert create_opts[:location] == "fsn1"
    end

    test "picks the x86 defaults when asked" do
      owner = self()

      create = fn _scope, _name, create_opts ->
        send(owner, {:created, create_opts})
        {:ok, %{"server" => server()}}
      end

      assert {:ok, _} =
               BurstBox.ensure_box(
                 platform_scope(),
                 "burst-platform",
                 creating_opts(create: create, architecture: :x86)
               )

      assert_received {:created, create_opts}
      assert create_opts[:server_type] == "cpx11"
      assert create_opts[:location] == "ash"
    end

    test "always carries the sweep's own role label, alongside any caller labels" do
      owner = self()

      create = fn _scope, _name, create_opts ->
        send(owner, {:created, create_opts[:labels]})
        {:ok, %{"server" => server()}}
      end

      assert {:ok, _} =
               BurstBox.ensure_box(
                 platform_scope(),
                 "burst-platform",
                 creating_opts(create: create, labels: %{"env" => "prod"})
               )

      assert_received {:created, labels}
      assert labels["cms-burst-role"] == "true"
      assert labels["env"] == "prod"
    end

    test "forwards ssh_key_ids and network_ids unchanged" do
      owner = self()

      create = fn _scope, _name, create_opts ->
        send(owner, {:created, create_opts[:ssh_key_ids], create_opts[:network_ids]})
        {:ok, %{"server" => server()}}
      end

      assert {:ok, _} =
               BurstBox.ensure_box(
                 platform_scope(),
                 "burst-platform",
                 creating_opts(create: create, ssh_key_ids: [1], network_ids: [2])
               )

      assert_received {:created, [1], [2]}
    end

    test "defaults :install_release to its own function when the caller supplies none" do
      ensure_image = fn _scope, _arch, opts ->
        assert is_function(Keyword.fetch!(opts, :install_release), 3)
        {:ok, 555}
      end

      assert {:ok, _} =
               BurstBox.ensure_box(
                 platform_scope(),
                 "burst-platform",
                 creating_opts(ensure_burst_box_image: ensure_image)
               )
    end

    test "a caller's own :install_release always wins" do
      marker = fn _run, _server, _opts -> :ok end

      ensure_image = fn _scope, _arch, opts ->
        assert Keyword.fetch!(opts, :install_release) == marker
        {:ok, 555}
      end

      assert {:ok, _} =
               BurstBox.ensure_box(
                 platform_scope(),
                 "burst-platform",
                 creating_opts(ensure_burst_box_image: ensure_image, install_release: marker)
               )
    end

    test "an image build failure is returned unchanged, and nothing is created" do
      ensure_image = fn _scope, _arch, _opts -> {:error, :image_build_failed} end
      create = fn _scope, _name, _opts -> flunk("must not create without an image") end

      assert {:error, :image_build_failed} =
               BurstBox.ensure_box(
                 platform_scope(),
                 "burst-platform",
                 creating_opts(ensure_burst_box_image: ensure_image, create: create)
               )
    end

    test "a creation failure is returned unchanged" do
      create = fn _scope, _name, _opts -> {:error, {:hetzner_error, 403, %{}}} end

      assert {:error, {:hetzner_error, 403, %{}}} =
               BurstBox.ensure_box(
                 platform_scope(),
                 "burst-platform",
                 creating_opts(create: create)
               )
    end
  end

  describe "ensure_box/3 — Fly peering, our own environment only" do
    test "applies the configured peer after creating our own environment's box" do
      {:ok, commands} = Agent.start_link(fn -> [] end)
      run = fn [cmd] -> Agent.update(commands, &(&1 ++ [cmd])) && {"", 0} end

      assert {:ok, _} =
               BurstBox.ensure_box(
                 platform_scope(),
                 "burst-platform",
                 creating_opts(fly_peer: peer(), run: run)
               )

      ran = Agent.get(commands, & &1)
      assert Enum.any?(ran, &String.contains?(&1, "wg-quick up #{FlyPeering.interface()}"))
    end

    test "never applies peering when creating a customer's box" do
      run = fn [_cmd] -> flunk("a customer's box must never be peered into Fly's 6PN") end

      assert {:ok, _} =
               BurstBox.ensure_box(
                 customer_scope(),
                 "burst-platform",
                 creating_opts(fly_peer: peer(), run: run)
               )
    end

    test "an already-existing box, ours or not, is never re-peered" do
      find = fn _scope, _name -> {:ok, server()} end
      run = fn [_cmd] -> flunk("an existing box must not be touched over SSH at all") end

      assert {:ok, _} =
               BurstBox.ensure_box(platform_scope(), "burst-platform",
                 find: find,
                 fly_peer: peer(),
                 run: run
               )
    end

    test "logs loudly, but still returns the box, when our own environment has no peer configured" do
      log =
        capture_log(fn ->
          assert {:ok, %{"id" => 7}} =
                   BurstBox.ensure_box(platform_scope(), "burst-platform", creating_opts())
        end)

      assert log =~ "no Fly peer configured"
    end

    test "logs loudly, but still returns the box, when applying the peer fails" do
      run = fn [_cmd] -> {"permission denied", 1} end

      log =
        capture_log(fn ->
          assert {:ok, %{"id" => 7}} =
                   BurstBox.ensure_box(
                     platform_scope(),
                     "burst-platform",
                     creating_opts(fly_peer: peer(), run: run)
                   )
        end)

      assert log =~ "could not apply Fly peering"
    end
  end

  describe "start_runner/5" do
    defp captured_command(opts) do
      {:ok, agent} = Agent.start_link(fn -> nil end)
      run = fn [cmd] -> Agent.update(agent, fn _ -> cmd end) && {"", 0} end

      assert :ok =
               BurstBox.start_runner(
                 platform_scope(),
                 server(),
                 "cms-flame-abc123",
                 %{"FLAME_PARENT" => "encoded", "PHX_SERVER" => "false"},
                 Keyword.put(opts, :run, run)
               )

      Agent.get(agent, & &1)
    end

    test "backgrounds the release detached, under the runner's own name" do
      command = captured_command([])

      assert command =~ "nohup #{BurstBox.release_path()}/bin/code_my_spec start"
      assert command =~ "</dev/null"
      assert command =~ ">#{BurstBox.release_path()}/run/cms-flame-abc123.log"
      assert command =~ "echo $! >#{BurstBox.release_path()}/run/cms-flame-abc123.pid"
    end

    test "exports the env it was given, plus its own runner name" do
      command = captured_command([])

      assert command =~ "FLAME_PARENT='encoded'"
      assert command =~ "PHX_SERVER='false'"
      assert command =~ "CMS_FLAME_RUNNER_NAME='cms-flame-abc123'"
    end

    test "exports CMS_FLAME_RUNNER_IP, stripped of its prefix, when a peer is configured" do
      command = captured_command(fly_peer_address: "fdaa:1:2::3/120")
      assert command =~ "CMS_FLAME_RUNNER_IP='fdaa:1:2::3'"
    end

    test "omits CMS_FLAME_RUNNER_IP entirely when no peer is configured" do
      refute captured_command([]) =~ "CMS_FLAME_RUNNER_IP"
    end

    test "uses a caller-given release path instead of the default" do
      command = captured_command(release_path: "/srv/cms")
      assert command =~ "/srv/cms/bin/code_my_spec start"
      assert command =~ "/srv/cms/run/cms-flame-abc123.pid"
    end

    test "an SSH failure is reported, not swallowed" do
      run = fn [_cmd] -> {"connection refused", 255} end

      assert {:error, {255, "connection refused"}} =
               BurstBox.start_runner(platform_scope(), server(), "cms-flame-abc123", %{},
                 run: run
               )
    end
  end

  describe "stop_runner/4" do
    test "kills exactly the pid file's process and removes it, guarded on the file existing" do
      {:ok, agent} = Agent.start_link(fn -> nil end)
      run = fn [cmd] -> Agent.update(agent, fn _ -> cmd end) && {"", 0} end

      assert :ok = BurstBox.stop_runner(platform_scope(), server(), "cms-flame-abc123", run: run)

      command = Agent.get(agent, & &1)
      assert command =~ "-f #{BurstBox.release_path()}/run/cms-flame-abc123.pid"
      assert command =~ "kill \"$(cat #{BurstBox.release_path()}/run/cms-flame-abc123.pid)\""
      assert command =~ "rm -f #{BurstBox.release_path()}/run/cms-flame-abc123.pid"
    end

    test "a different runner's pid file is never named" do
      {:ok, agent} = Agent.start_link(fn -> nil end)
      run = fn [cmd] -> Agent.update(agent, fn _ -> cmd end) && {"", 0} end

      BurstBox.stop_runner(platform_scope(), server(), "cms-flame-abc123", run: run)

      refute Agent.get(agent, & &1) =~ "cms-flame-def456"
    end

    test "an SSH failure is reported, not swallowed" do
      run = fn [_cmd] -> {"connection refused", 255} end

      assert {:error, {255, "connection refused"}} =
               BurstBox.stop_runner(platform_scope(), server(), "cms-flame-abc123", run: run)
    end
  end

  describe "build_in_progress?/3" do
    test "true when docker ps finds a container under the build-marker label" do
      run = fn [cmd] ->
        assert cmd =~ "docker ps -q --filter label=cms-build-in-progress"
        {"800ac1dcb78a\n", 0}
      end

      assert BurstBox.build_in_progress?(platform_scope(), server(), run: run)
    end

    test "false when docker ps finds nothing under the label" do
      run = fn [_cmd] -> {"", 0} end

      refute BurstBox.build_in_progress?(platform_scope(), server(), run: run)
    end

    test "a check that cannot be made reads as busy, not idle" do
      run = fn [_cmd] -> {"connection refused", 255} end

      log =
        capture_log(fn ->
          assert BurstBox.build_in_progress?(platform_scope(), server(), run: run)
        end)

      assert log =~ "could not check"
      assert log =~ "treating it as busy"
    end
  end

  describe "busy?/3" do
    test "true when a build is in progress, with no embed check configured" do
      run = fn [_cmd] -> {"800ac1dcb78a\n", 0} end

      assert BurstBox.busy?(platform_scope(), server(), run: run)
    end

    test "false when nothing is building and no embed check is configured" do
      run = fn [_cmd] -> {"", 0} end

      refute BurstBox.busy?(platform_scope(), server(), run: run)
    end

    test "true when the embed check alone says so, even with no build running" do
      run = fn [_cmd] -> {"", 0} end

      assert BurstBox.busy?(platform_scope(), server(),
               run: run,
               embed_runner_busy?: fn -> true end
             )
    end

    test "true when both halves say so" do
      run = fn [_cmd] -> {"800ac1dcb78a\n", 0} end

      assert BurstBox.busy?(platform_scope(), server(),
               run: run,
               embed_runner_busy?: fn -> true end
             )
    end

    test "the embed check is never consulted when the docker half already says busy" do
      run = fn [_cmd] -> {"800ac1dcb78a\n", 0} end
      embed_runner_busy? = fn -> flunk("docker ps already found a build — no need to ask") end

      assert BurstBox.busy?(platform_scope(), server(),
               run: run,
               embed_runner_busy?: embed_runner_busy?
             )
    end
  end

  defp release_opts(opts) do
    Keyword.put(opts, :version_lookup, fn ref ->
      {:ok, ref <> String.duplicate("0", 40 - byte_size(ref)), []}
    end)
  end

  describe "install_release/3" do
    # The build marker's own start/stop commands (`Remote.build/4`'s own
    # concern — see its moduledoc) answer the same way in every one of these
    # tests, so they are baked in here rather than repeated in every
    # `responses` list below.
    defp recorder(responses) do
      responses =
        responses ++
          [
            {"docker run -d --label cms-build-in-progress", {"marker123\n", 0}},
            {"docker rm -f", {"", 0}}
          ]

      fn [command] ->
        Enum.find_value(responses, fn {pattern, response} ->
          String.contains?(command, pattern) && response
        end) || flunk("unexpected command: #{command}")
      end
    end

    test "requires :ref, with no silent default" do
      assert_raise KeyError, fn ->
        BurstBox.install_release(fn [_] -> {"", 0} end, server(), [])
      end
    end

    test "builds, verifies the architecture, extracts /app, and never pushes" do
      owner = self()
      box = server(%{"server_type" => %{"architecture" => "x86"}})

      run =
        recorder([
          {"true", {"", 0}},
          {"docker build --force-rm", {"", 0}},
          {"docker image inspect", {"amd64\n", 0}},
          {"docker create cms-release:abc123", {"container123\n", 0}},
          {"rm -rf /opt/cms-release && docker cp container123:/app /opt/cms-release", {"", 0}},
          {"docker rm container123", {"", 0}}
        ])

      deliver = fn ref, dir ->
        send(owner, {:delivered, ref, dir})
        :ok
      end

      assert :ok =
               BurstBox.install_release(
                 run,
                 box,
                 release_opts(ref: "abc123", deliver: deliver, push: true)
               )

      assert_received {:delivered, "abc123", "/build"}
    end

    test "a build that produced the wrong architecture is never extracted" do
      box = server(%{"server_type" => %{"architecture" => "arm"}})

      run =
        recorder([
          {"true", {"", 0}},
          {"docker build --force-rm", {"", 0}},
          # the box wants arm; the build quietly produced x86
          {"docker image inspect", {"amd64\n", 0}}
        ])

      deliver = fn _ref, _dir -> :ok end

      assert {:error, {:architecture_mismatch, built: :x86, wanted: :arm}} =
               BurstBox.install_release(run, box, release_opts(ref: "abc123", deliver: deliver))
    end

    test "proceeds when the box reports no architecture at all" do
      box = server()

      run =
        recorder([
          {"true", {"", 0}},
          {"docker build --force-rm", {"", 0}},
          {"docker image inspect", {"arm64\n", 0}},
          {"docker create", {"container123\n", 0}},
          {"docker cp", {"", 0}},
          {"docker rm", {"", 0}}
        ])

      deliver = fn _ref, _dir -> :ok end

      assert :ok =
               BurstBox.install_release(run, box, release_opts(ref: "abc123", deliver: deliver))
    end

    test "a failed build is reported and nothing is extracted" do
      box = server()

      run =
        recorder([
          {"true", {"", 0}},
          {"docker build --force-rm", {"no space left on device", 1}}
        ])

      deliver = fn _ref, _dir -> :ok end

      assert {:error, {:build_failed, 1, _output}} =
               BurstBox.install_release(run, box, release_opts(ref: "abc123", deliver: deliver))
    end

    test "a failed extraction is reported with what docker said" do
      box = server(%{"server_type" => %{"architecture" => "arm"}})

      run =
        recorder([
          {"true", {"", 0}},
          {"docker build --force-rm", {"", 0}},
          {"docker image inspect", {"arm64\n", 0}},
          {"docker create", {"", 125}}
        ])

      deliver = fn _ref, _dir -> :ok end

      assert {:error, {:release_extract_failed, 125, _output}} =
               BurstBox.install_release(run, box, release_opts(ref: "abc123", deliver: deliver))
    end
  end
end
