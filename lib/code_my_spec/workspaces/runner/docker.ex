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

  # A dev box (story 1140): Docker is a provider like the others. The box runs
  # on the machine that has the daemon, so it is a `:local` kind.
  @impl true
  def id, do: :docker

  @impl true
  def label, do: "Docker"

  @impl true
  def kind, do: :local

  @impl true
  def instructions(_context) do
    [
      %{
        key: "docker-container",
        copy: "copy-docker-container",
        title: "Your container",
        body:
          "A container was started for this box. Its token is mounted into it as a read-only " <>
            "file, not set in its environment, so `docker inspect` does not show it. Stopping " <>
            "and starting the container brings the same box back."
      }
    ]
  end

  @impl true
  def start(container_name, app_name, port, env \\ [], opts \\ []) do
    # The name is derived from the project, so a second boot for the same
    # project collides with whatever the first one left behind — `docker run`
    # exits 125 and the visitor never gets a workspace. Booting replaces.
    with :ok <- reachable() do
      run(container_name, app_name, port, env, opts)
    end
  end

  # Whether a daemon answers is asked of the daemon, not read off an error's
  # wording: Docker 29 says "failed to connect to the docker API" where 28 said
  # "Cannot connect to the Docker daemon", and the next release will word it
  # differently again. Any failure of `docker version` is "not reachable".
  defp reachable do
    case docker(["version", "--format", "{{.Server.Version}}"]) do
      {_out, 0} -> :ok
      {_out, _code} -> {:error, :docker_unreachable}
    end
  end

  defp run(container_name, app_name, port, env, opts) do
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
        file_args(container_name, Keyword.get(opts, :files, [])) ++
        [
          "--publish",
          "#{port}:#{@app_port}",
          image()
        ]

    case docker(args) do
      {_out, 0} -> :ok
      {_out, 127} -> {:error, :docker_unreachable}
      {out, code} -> run_failed(out, code)
    end
  end

  # No daemon answering is a state a person can fix, so it gets a name of its own
  # instead of `docker run`'s text.
  defp run_failed(out, code) do
    if String.contains?(out, "Cannot connect to the Docker daemon") or
         String.contains?(out, "Is the docker daemon running"),
       do: {:error, :docker_unreachable},
       else: {:error, "docker run exited #{code}: #{String.trim(out)}"}
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

  # A secret goes in as a read-only bind-mounted file. The host copy lives under
  # this machine's state dir (0600, in a 0700 directory) and is kept, so the
  # same container, stopped and started, still finds it.
  defp file_args(container_name, files) do
    Enum.flat_map(files, fn {container_path, contents} ->
      host_path = secret_path(container_name, container_path)
      File.mkdir_p!(Path.dirname(host_path))
      File.chmod!(Path.dirname(host_path), 0o700)
      File.write!(host_path, contents)
      File.chmod!(host_path, 0o444)
      ["--volume", "#{host_path}:#{container_path}:ro"]
    end)
  end

  defp secret_path(container_name, container_path) do
    Path.join([
      Path.expand(CodeMySpec.Paths.local_state_dir()),
      "devbox-secrets",
      container_name,
      Path.basename(container_path)
    ])
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
