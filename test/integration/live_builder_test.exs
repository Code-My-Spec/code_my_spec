defmodule CodeMySpec.LiveBuilderTest do
  @moduledoc """
  One real builder, end to end, on real infrastructure.

  Local Docker already covers everything that happens *on* the box — fetch,
  build, push, inspect, and the failure modes. What it cannot cover is the box
  itself, which is exactly three things:

    * a freshly created server becomes reachable over SSH at all
    * Hetzner's `docker-ce` image really does arrive with Docker installed
    * the builder is destroyed afterwards

  Those are the claims that cost money when they quietly stop being true, so
  they are proved against the real provider rather than recorded.

  Tagged `:live` and excluded by default. It creates a real server and deletes
  it; teardown is registered before the server exists, so a failure anywhere
  after creation still takes the box with it.

      MIX_ENV=test mix test --include live test/integration/live_builder_test.exs
  """
  # Sync: shells out, and writes the shared `:code_my_spec, Hetzner` key. Tagged
  # out of the default suite besides — it talks to real infrastructure.
  use ExUnit.Case, async: false

  alias CodeMySpec.Provisioning.{Builder, Hetzner}
  alias CodeMySpec.Users.Scope

  @moduletag :live
  @moduletag timeout: 600_000

  setup do
    token = System.get_env("HETZNER_API_TOKEN")
    ensure_token!(token)

    Application.put_env(:code_my_spec, Hetzner, api_token: token)

    # A key for this run only. Uploaded so the server accepts it, removed after
    # so the account does not accumulate one key per QA pass.
    dir = CodeMySpec.TempFile.dir("cms-live-builder")
    File.mkdir_p!(dir)
    key_path = Path.join(dir, "id_ed25519")
    name = "cms-live-builder-#{System.unique_integer([:positive])}"

    {_, 0} =
      System.cmd("ssh-keygen", ["-t", "ed25519", "-N", "", "-C", name, "-f", key_path],
        stderr_to_stdout: true
      )

    scope = %Scope{}
    {:ok, key} = Hetzner.ensure_ssh_key(scope, name, File.read!(key_path <> ".pub"))

    on_exit(fn ->
      Hetzner.delete_ssh_key(scope, key["id"])
      File.rm_rf(dir)
    end)

    %{scope: scope, key: key, key_path: key_path, name: name}
  end

  test "a real builder boots with Docker, builds, and is destroyed", ctx do
    # The build is scripted rather than a real project: what is under test here
    # is the box, and a real Elixir release compile would spend five minutes
    # proving something local Docker already proved in two seconds.
    build = fn _scope, server, _ref, architecture ->
      run = ssh_runner(server, ctx.key_path)

      # Reachability first — the claim that a fresh box answers SSH at all.
      :ok = await_ssh(run, 60)

      # And that `docker-ce` means Docker is already there, with nothing to
      # install. This is the whole reason for choosing that image.
      {version, 0} = run.("docker --version")
      assert version =~ "Docker version"

      {_, 0} = run.("printf 'FROM alpine:3\\nRUN echo ok > /ok\\n' > /tmp/Dockerfile")

      {_, 0} = run.("cd /tmp && docker build -q -t live-probe:1 .")
      {arch, 0} = run.("docker image inspect --format '{{.Architecture}}' live-probe:1")

      {:ok, %{reference: "live-probe:1", architecture: architecture(String.trim(arch))}}
    end

    destroyed = self()

    assert {:ok, result} =
             Builder.build(ctx.scope, ctx.name,
               # x86, because no ARM type is available at Hetzner right now.
               architecture: :x86,
               ssh_key_ids: [ctx.key["id"]],
               build: build,
               destroy: fn scope, id ->
                 send(destroyed, {:destroying, id})
                 Hetzner.delete_server(scope, id)
               end
             )

    assert result.architecture == :x86
    assert_received {:destroying, _server_id}

    # Asked of Hetzner, not inferred from our own call returning ok. A delete
    # that was accepted and not performed is the failure this is here to catch.
    assert eventually_absent(ctx.scope, "builder-" <> String.slice(ctx.name, 0, 12), 30),
           "the builder was still in the account after the build finished"
  end

  defp architecture("arm64"), do: :arm
  defp architecture("aarch64"), do: :arm
  defp architecture("amd64"), do: :x86
  defp architecture("x86_64"), do: :x86
  defp architecture(other), do: {:unexpected, other}

  defp ssh_runner(server, key_path) do
    # Hetzner wraps the created server in a "server" key. Reading through it
    # rather than around it: the previous version silently produced a nil host
    # and spent three minutes failing to SSH to `root@`.
    ip = ip(server)

    fn command ->
      System.cmd(
        "ssh",
        [
          "-o",
          "StrictHostKeyChecking=no",
          "-o",
          "UserKnownHostsFile=/dev/null",
          "-o",
          # Otherwise every command's output carries SSH's known-hosts warning,
          # which is noise on stderr that a caller has to know to ignore.
          "LogLevel=ERROR",
          "-o",
          "ConnectTimeout=5",
          "-i",
          key_path,
          "root@#{ip}",
          command
        ],
        stderr_to_stdout: true
      )
    end
  end

  defp ensure_token!(token) when is_binary(token) and token != "", do: :ok
  defp ensure_token!(_token), do: raise("HETZNER_API_TOKEN is not set — source envs/.env first")

  defp ip(%{"server" => server}), do: ip(server)
  defp ip(%{"public_net" => %{"ipv4" => %{"ip" => ip}}}), do: ip
  defp ip(%{"ip" => ip}), do: ip

  defp await_ssh(_run, 0), do: {:error, :unreachable}

  defp await_ssh(run, attempts), do: await_ssh_result(run.("true"), run, attempts)

  defp await_ssh_result({_, 0}, _run, _attempts), do: :ok

  defp await_ssh_result(_other, run, attempts) do
    Process.sleep(3_000)
    await_ssh(run, attempts - 1)
  end

  defp eventually_absent(_scope, _name, 0), do: false

  defp eventually_absent(scope, name, attempts),
    do: eventually_absent_result(Hetzner.find_server(scope, name), scope, name, attempts)

  defp eventually_absent_result({:error, :not_found}, _scope, _name, _attempts), do: true

  defp eventually_absent_result(_other, scope, name, attempts) do
    Process.sleep(2_000)
    eventually_absent(scope, name, attempts - 1)
  end
end
