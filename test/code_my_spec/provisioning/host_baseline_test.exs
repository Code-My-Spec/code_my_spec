defmodule CodeMySpec.Provisioning.HostBaselineTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.HostBaseline

  setup do
    directory =
      Path.join(System.tmp_dir!(), "cms-host-baseline-#{System.unique_integer([:positive])}")

    bin = Path.join(directory, "bin")
    config = Path.join(directory, "docker")
    File.mkdir_p!(bin)
    File.mkdir_p!(config)
    on_exit(fn -> File.rm_rf!(directory) end)

    scripts = %{
      "docker" =>
        "#!/bin/sh\nif [ \"$1\" = ps ]; then printf '%s' \"$RUNNING\"; else printf '%s\\n' \"${ACTIVE_DRIVER:-local}\"; fi\n",
      "dockerd" =>
        "#!/bin/sh\n[ \"$FAIL_VALIDATE\" != 1 ] || exit 9\nexec python3 -m json.tool \"$3\" >/dev/null\n",
      "systemctl" =>
        "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"$RESTART_LOG\"\n[ \"$FAIL_RESTART\" != 1 ]\n"
    }

    for {name, content} <- scripts do
      path = Path.join(bin, name)
      File.write!(path, content)
      File.chmod!(path, 0o755)
    end

    env = [
      {"PATH", bin <> ":" <> System.get_env("PATH")},
      {"RESTART_LOG", Path.join(directory, "restarts")},
      {"FAIL_VALIDATE", "0"},
      {"FAIL_RESTART", "0"},
      {"RUNNING", ""}
    ]

    {:ok, config: config, path: Path.join(config, "daemon.json"), env: env}
  end

  test "preserves unrelated settings and registries, then reruns without restarting", ctx do
    File.write!(
      ctx.path,
      Jason.encode!(%{"live-restore" => true, "insecure-registries" => ["10.1.0.2:5000"]})
    )

    assert {_, 0} = execute(ctx, "10.2.0.2:5000")
    configured = Jason.decode!(File.read!(ctx.path))
    assert configured["live-restore"] == true
    assert configured["insecure-registries"] == ["10.1.0.2:5000", "10.2.0.2:5000"]
    assert configured["log-driver"] == "local"

    assert configured["log-opts"] == %{
             "max-size" => "20m",
             "max-file" => "5",
             "compress" => "true"
           }

    before = File.read!(ctx.path)
    assert {_, 0} = execute(ctx, "10.2.0.2:5000")
    assert File.read!(ctx.path) == before
    assert File.read!(restart_log(ctx)) == "restart\n"
  end

  test "invalid existing JSON is preserved without a restart", ctx do
    File.write!(ctx.path, "invalid json")
    assert {_, status} = execute(ctx, nil)
    assert status != 0
    assert File.read!(ctx.path) == "invalid json"
    refute File.exists?(restart_log(ctx))
  end

  test "daemon validation failure leaves the old file intact", ctx do
    File.write!(ctx.path, "{}")
    ctx = %{ctx | env: List.keystore(ctx.env, "FAIL_VALIDATE", 0, {"FAIL_VALIDATE", "1"})}
    assert {_, status} = execute(ctx, nil)
    assert status != 0
    assert File.read!(ctx.path) == "{}"
    refute File.exists?(restart_log(ctx))
  end

  test "failed restart restores the previous configuration", ctx do
    File.write!(ctx.path, "{}")
    ctx = %{ctx | env: List.keystore(ctx.env, "FAIL_RESTART", 0, {"FAIL_RESTART", "1"})}
    assert {_, status} = execute(ctx, nil)
    assert status != 0
    assert File.read!(ctx.path) == "{}"
    assert File.read!(restart_log(ctx)) == "restart\nrestart\n"
  end

  # The server step restarted Docker on a box already serving customer apps,
  # and every container went down with it.
  describe "a box already running containers" do
    setup ctx do
      %{ctx | env: List.keystore(ctx.env, "RUNNING", 0, {"RUNNING", "abc123\n"})}
    end

    test "is reloaded, never restarted, when its configuration changes", ctx do
      File.write!(ctx.path, "{}")

      assert {_, 0} = execute(ctx, "10.2.0.2:5000")
      configured = Jason.decode!(File.read!(ctx.path))
      assert configured["live-restore"] == true
      assert configured["insecure-registries"] == ["10.2.0.2:5000"]
      assert File.read!(restart_log(ctx)) == "reload\n"
    end

    test "is left alone when only the active log driver differs", ctx do
      File.write!(ctx.path, Jason.encode!(desired()))

      ctx = %{
        ctx
        | env: List.keystore(ctx.env, "ACTIVE_DRIVER", 0, {"ACTIVE_DRIVER", "json-file"})
      }

      assert {_, 0} = execute(ctx, nil)
      refute File.exists?(restart_log(ctx))
    end

    test "a failed reload restores the previous configuration", ctx do
      File.write!(ctx.path, "{}")
      ctx = %{ctx | env: List.keystore(ctx.env, "FAIL_RESTART", 0, {"FAIL_RESTART", "1"})}

      assert {_, status} = execute(ctx, nil)
      assert status != 0
      assert File.read!(ctx.path) == "{}"
      assert File.read!(restart_log(ctx)) == "reload\n"
    end
  end

  defp desired do
    %{
      "log-driver" => "local",
      "live-restore" => true,
      "log-opts" => %{"max-size" => "20m", "max-file" => "5", "compress" => "true"}
    }
  end

  test "baseline stops on failure and suppresses remote output" do
    run = fn [_command] ->
      send(self(), :ran)
      {"sensitive output", 42}
    end

    assert {:error, "Docker logging configuration failed (exit 42)"} = HostBaseline.ensure(run)
    assert_received :ran
    refute_received :ran
  end

  defp execute(ctx, registry) do
    command = HostBaseline.docker_command(registry) |> String.replace("/etc/docker", ctx.config)
    System.cmd("sh", ["-c", command], env: ctx.env, stderr_to_stdout: true)
  end

  defp restart_log(ctx), do: ctx.env |> List.keyfind("RESTART_LOG", 0) |> elem(1)
end
