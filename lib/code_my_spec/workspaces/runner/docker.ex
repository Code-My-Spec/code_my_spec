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
  def start(container_name, app_name, port, env \\ []) do
    # The name is derived from the project, so a second boot for the same
    # project collides with whatever the first one left behind — `docker run`
    # exits 125 and the visitor never gets a workspace. Booting replaces.
    stop(container_name)

    args =
      [
        "run",
        "--detach",
        "--name",
        container_name,
        "--env",
        "APP_NAME=#{app_name}"
      ] ++
        env_args(env) ++
        [
          "--publish",
          "#{port}:#{@app_port}",
          image()
        ]

    case docker(args) do
      {_out, 0} -> :ok
      {out, code} -> {:error, "docker run exited #{code}: #{String.trim(out)}"}
    end
  end

  # An HTTP round-trip, not a TCP connect. Docker publishes the host port the
  # moment the container starts, so a connect succeeds while the app inside is
  # still fetching deps — which told the visitor "it's running" and handed them
  # a link to a dead page. Any HTTP response means something is actually
  # serving; the status does not matter.
  @impl true
  def healthy?(port) when is_integer(port), do: serving(port) != :down

  # The status matters here, where it deliberately does not for healthy?/1.
  # Waiting for a boot, any answer means the app is up; once it is up, an
  # answer of 500 means it is broken, and the pane has to say which.
  @impl true
  def serving(port) when is_integer(port) do
    case get(port) do
      {:ok, %Req.Response{status: status}} when status >= 500 -> :erroring
      {:ok, %Req.Response{}} -> :serving
      _ -> :down
    end
  end

  defp get(port) do
    Req.get("http://127.0.0.1:#{port}/",
      retry: false,
      receive_timeout: 2_000,
      connect_options: [timeout: 1_000]
    )
  end

  # Loopback, because that is where a published port is. The hosted runner
  # answers a preview-{id} subdomain instead — same-site, so a browser showing
  # it in an iframe keeps sending the target's session cookie.
  @impl true
  def url(_container_name, port), do: "http://localhost:#{port}"

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

  # One `--env` pair per entry. Values are passed as separate argv elements
  # rather than interpolated into a shell string, because one of them is a
  # deploy key and the other is an id, and neither should ever be somewhere a
  # shell could look at it.
  defp env_args(env) do
    Enum.flat_map(env, fn {key, value} -> ["--env", "#{key}=#{value}"] end)
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
