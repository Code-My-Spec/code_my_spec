defmodule CodeMySpec.Workspaces.Runner.DockerDevBoxTest do
  @moduledoc """
  Story 1140: Docker is a dev box provider, and a Docker that is not there is
  said so rather than reported as a failed `docker run`.
  """
  use ExUnit.Case, async: false

  alias CodeMySpec.Workspaces.Runner
  alias CodeMySpec.Workspaces.Runner.Docker

  test "Docker is listed as a dev box provider, a local kind of machine" do
    assert Runner.dev_box("docker") == Docker
    assert Docker.label() == "Docker"
    assert Docker.kind() == :local
  end

  test "its instructions say the token is a file, not an environment variable" do
    [section] = Docker.instructions(%{token: "cbt_x", server_url: "http://x"})

    assert section.body =~ "read-only file"
    refute section.body =~ "cbt_x"
  end

  test "with no docker on the PATH, starting is `docker_unreachable`" do
    previous = System.get_env("PATH")
    System.put_env("PATH", "/nonexistent")
    on_exit(fn -> System.put_env("PATH", previous) end)

    assert {:error, :docker_unreachable} = Docker.start("devbox-test", "devbox", 4999, [])
  end

  describe "a docker CLI with no daemon behind it" do
    setup do
      dir = Path.join(System.tmp_dir!(), "fake_docker_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      previous = System.get_env("PATH")

      on_exit(fn ->
        System.put_env("PATH", previous)
        File.rm_rf(dir)
      end)

      %{dir: dir}
    end

    # The words Docker CLI 29.6.1 prints for `docker version` and `docker run`
    # alike when nothing answers on the socket (issue 09b26ed0).
    @docker_29 "failed to connect to the docker API at unix:///var/run/docker.sock; " <>
                 "check if the path is correct and if the daemon is running: " <>
                 "dial unix /var/run/docker.sock: connect: no such file or directory"

    defp restore_workspaces_config(nil),
      do: Application.delete_env(:code_my_spec, CodeMySpec.Workspaces)

    defp restore_workspaces_config(value),
      do: Application.put_env(:code_my_spec, CodeMySpec.Workspaces, value)

    defp install_docker(dir, script) do
      path = Path.join(dir, "docker")
      File.write!(path, "#!/bin/sh\n" <> script)
      File.chmod!(path, 0o755)
      System.put_env("PATH", dir <> ":" <> System.get_env("PATH"))
    end

    test "Docker 29's error is not reachable, whatever its wording", %{dir: dir} do
      install_docker(dir, "echo '#{@docker_29}' >&2\nexit 1\n")

      assert {:error, :docker_unreachable} = Docker.start("devbox-test", "devbox", 4999, [])
    end

    test "an error no one has heard of is still not reachable when the daemon does not answer",
         %{dir: dir} do
      install_docker(dir, "echo 'a message from the future' >&2\nexit 1\n")

      assert {:error, :docker_unreachable} = Docker.start("devbox-test", "devbox", 4999, [])
    end

    test "a daemon that answers but cannot run the container is the docker error, not unreachable",
         %{dir: dir} do
      install_docker(
        dir,
        "case \"$1\" in version) echo 29.0.0; exit 0;; rm) exit 0;; esac\necho 'no such image' >&2\nexit 125\n"
      )

      assert {:error, "docker run exited 125: no such image"} =
               Docker.start("devbox-test", "devbox", 4999, [])
    end

    test "a Docker box is started by Docker even when the app's instance runner is Local",
         %{dir: dir} do
      install_docker(dir, "echo '#{@docker_29}' >&2\nexit 1\n")
      previous = Application.get_env(:code_my_spec, CodeMySpec.Workspaces)
      Application.put_env(:code_my_spec, CodeMySpec.Workspaces, runner: Runner.Local)

      on_exit(fn -> restore_workspaces_config(previous) end)

      box = %CodeMySpec.Devices.Device{id: Ecto.UUID.generate(), provider: :docker}

      assert {:error, :docker_unreachable} =
               CodeMySpec.Workspaces.start_dev_box(box, "cbt_x", "http://x")
    end
  end
end
