defmodule CodeMySpec.Workspaces.Runner.Docker do
  @moduledoc """
  Runs an instance as a devbox container on the local Docker daemon.

  Uses the image's default entrypoint, which generates the app with
  `mix cms.new` and needs no repo — `new-project.sh` wants a GitHub repo and a
  token, which a visitor who has not signed up does not have.
  """

  @behaviour CodeMySpec.Workspaces.Runner

  alias CodeMySpec.Environments

  require Logger

  @image "codemyspec/devbox:latest"
  @app_port 4000

  @impl true
  def start(container_name, app_name, port) do
    args = [
      "run",
      "--detach",
      "--name",
      container_name,
      "--env",
      "APP_NAME=#{app_name}",
      "--publish",
      "#{port}:#{@app_port}",
      image()
    ]

    case docker(args) do
      {_out, 0} -> :ok
      {out, code} -> {:error, "docker run exited #{code}: #{String.trim(out)}"}
    end
  end

  @impl true
  def healthy?(port) when is_integer(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  @impl true
  def alive?(container_name) do
    case docker(["inspect", "--format", "{{.State.Running}}", container_name]) do
      {out, 0} -> String.trim(out) == "true"
      {_out, _code} -> false
    end
  end

  @impl true
  def logs(container_name) do
    case docker(["logs", container_name]) do
      {out, 0} -> out
      {_out, _code} -> ""
    end
  end

  @impl true
  def stop(container_name) do
    docker(["rm", "--force", container_name])
    :ok
  end

  defp image do
    :code_my_spec
    |> Application.get_env(CodeMySpec.Workspaces, [])
    |> Keyword.get(:image, @image)
  end

  # clean_otp_env clears the Burrito release's ROOTDIR/BINDIR/RELEASE_* so a
  # published binary's env doesn't leak into the child process.
  defp docker(args), do: docker(System.find_executable("docker"), args)

  defp docker(nil, _args) do
    Logger.error("docker executable not found on PATH")
    {"docker executable not found", 127}
  end

  defp docker(executable, args) do
    System.cmd(executable, args, stderr_to_stdout: true, env: Environments.clean_otp_env())
  end
end
