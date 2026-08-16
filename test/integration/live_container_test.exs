defmodule CodeMySpec.LiveContainerTest do
  @moduledoc """
  Proves `Environments.Container` against a real Docker daemon.

  Excluded by default (`:live`). Needs `docker` on the host — which is the
  point: every operation here is a `docker` invocation, and a stubbed daemon
  would prove the arguments were assembled, not that Docker accepted them.

  Uses `alpine` rather than the provisioning runner image because nothing here
  is about the toolchain — it is about whether the environment contract holds
  when the filesystem is inside a container.
  """
  use ExUnit.Case, async: true

  @moduletag :live
  @moduletag timeout: 600_000

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Container

  @image "alpine:3"

  setup do
    {_, 0} = System.cmd("docker", ["pull", @image], stderr_to_stdout: true)

    {:ok, env} = Container.create(image: @image, env: [PROVISIONING: "1"])
    on_exit(fn -> Container.destroy(env) end)

    %{env: env}
  end

  test "a command runs inside the container, not on the host", %{env: env} do
    {output, 0} = Environments.cmd(env, "sh", ["-c", "cat /etc/os-release | head -1"])

    assert output =~ "Alpine", "the command ran on the host, not in the container"

    IO.puts("\n  runs in    -> #{String.trim(output)}")
  end

  test "the working directory is the workspace every step assumes", %{env: env} do
    {output, 0} = Environments.cmd(env, "pwd", [])

    assert String.trim(output) == "/workspace"
  end

  test "environment variables reach the container", %{env: env} do
    {output, 0} = Environments.cmd(env, "sh", ["-c", "echo $PROVISIONING"])

    assert String.trim(output) == "1"
  end

  test "a file written is a file read back", %{env: env} do
    content = ".sops.yaml round trip\nwith a second line\n"

    assert :ok = Environments.write_file(env, ".sops.yaml", content)
    assert {:ok, ^content} = Environments.read_file(env, ".sops.yaml")

    # And it is genuinely on the container's filesystem, not ours.
    {output, 0} = Environments.cmd(env, "cat", [".sops.yaml"])
    assert output =~ "round trip"

    refute File.exists?(Path.join(System.tmp_dir!(), ".sops.yaml"))

    IO.puts("  file       -> written and read back inside the container")
  end

  test "writing into a directory that does not exist yet creates it", %{env: env} do
    assert :ok = Environments.write_file(env, "envs/prod.enc.env", "SOPS=1\n")
    assert {:ok, "SOPS=1\n"} = Environments.read_file(env, "envs/prod.enc.env")
  end

  test "binary content survives the round trip", %{env: env} do
    # `docker cp` rather than base64-through-a-shell-argument is the reason
    # this holds; the argument-length ceiling would be the other failure.
    content = :crypto.strong_rand_bytes(64_000)

    assert :ok = Environments.write_file(env, "blob.bin", content)
    assert {:ok, ^content} = Environments.read_file(env, "blob.bin")

    IO.puts("  binary     -> 64KB round trip intact")
  end

  test "existence, listing and globbing see the container's filesystem", %{env: env} do
    :ok = Environments.write_file(env, "lib/a.ex", "defmodule A do end\n")
    :ok = Environments.write_file(env, "lib/nested/b.ex", "defmodule B do end\n")

    assert Environments.file_exists?(env, "lib/a.ex")
    refute Environments.file_exists?(env, "lib/missing.ex")

    {:ok, entries} = Environments.list_directory(env, "lib")
    assert "a.ex" in entries

    found = Environments.glob(env, "lib/**/*.ex")
    assert Enum.any?(found, &String.ends_with?(&1, "b.ex")), "glob missed the nested file"

    IO.puts("  glob       -> #{length(found)} file(s) under lib")
  end

  test "an executable is distinguished from a file that merely exists", %{env: env} do
    :ok = Environments.write_file(env, "bin/deploy", "#!/bin/sh\necho hi\n")

    refute Environments.exec_file_exists?(env, "bin/deploy"),
           "a freshly copied file should not be executable yet"

    {_, 0} = Environments.cmd(env, "chmod", ["+x", "bin/deploy"])

    assert Environments.exec_file_exists?(env, "bin/deploy"),
           "the deploy step gates on this, so it has to track the mode bit"
  end

  test "a failing command reports its exit status rather than raising", %{env: env} do
    {output, status} = Environments.cmd(env, "sh", ["-c", "echo nope >&2; exit 3"])

    assert status == 3
    assert output =~ "nope"
  end

  test "destroy removes the container", %{env: env} do
    name = Container.container(env)

    assert :ok = Container.destroy(env)

    {output, _} =
      System.cmd("docker", ["ps", "-a", "--filter", "name=#{name}", "--format", "{{.Names}}"],
        stderr_to_stdout: true
      )

    refute String.contains?(output, name),
           "the container outlived the run, and a container left running bills quietly"

    IO.puts("  destroy    -> #{name} gone")
  end
end
