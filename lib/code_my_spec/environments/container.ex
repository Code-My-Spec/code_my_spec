defmodule CodeMySpec.Environments.Container do
  @moduledoc """
  An environment that is a Docker container we drive.

  Every operation is a `docker` invocation against one container, named in the
  environment's `ref`. Nothing here knows or cares which machine the daemon is
  on: `DOCKER_HOST` already means "which daemon", and it accepts
  `ssh://user@host`, so pointing this at a box in Hetzner is configuration
  rather than a second transport to write and debug.

  ## Why this type exists

  The provisioning sequence shells out — `git`, `kamal`, `sops`, `mix` — and
  those need a checkout to operate on. The hosted app has no checkout and must
  not grow one: a `mix compile` or an image build on the box serving requests
  contends with serving them, and an agent that fills the disk takes the
  product down.

  So a run gets a container, works in it, pushes from it, and it is destroyed.

  ## One container per run, not per call and not per customer

  Per call is wrong because the sequence carries state: the clone made by the
  repository step is what the secrets step writes into and the deploy step
  builds from. Per customer is wrong because this container runs
  agent-written code *and* would hold that customer's keys — and `kamal` needs
  Docker, so a shared container needs either DinD or the host's Docker socket,
  and the socket is root on the host running everybody else's agents.

  Ephemeral is also the cheaper answer, which is the part that surprises: the
  work is bursty rather than resident, so a container that lives for one run
  costs nothing between runs, while N resident tenants cost continuously.

  ## Files move with `docker cp`, not through the command line

  `write_file/3` could base64 the content into a `docker exec sh -c`, and for
  `.sops.yaml` it would work. It would also silently acquire an argument-length
  ceiling that the first larger file discovers in production. `docker cp`
  streams, handles binary, and has no such limit.
  """

  @behaviour CodeMySpec.Environments.EnvironmentsBehaviour

  require Logger

  alias CodeMySpec.Environments.Environment

  # Where a run's checkout lives inside the container. Fixed rather than
  # configurable: every step agrees on it, and a path that varies per call is
  # a class of bug with no upside.
  @workdir "/workspace"

  @default_image "codemyspec/provisioning-runner:latest"

  ## Lifecycle

  @doc """
  Start a container and return an environment addressing it.

  `opts`:
    * `:image` — defaults to the provisioning runner image
    * `:name` — container name; one is generated when absent
    * `:env` — environment variables to inject, as a keyword list
    * `:workdir` — defaults to `#{@workdir}`
  """
  @impl true
  def create(opts) do
    image = Keyword.get(opts, :image, @default_image)
    workdir = Keyword.get(opts, :workdir, @workdir)
    name = Keyword.get(opts, :name) || generate_name()

    args =
      ["run", "--detach", "--name", name, "--workdir", workdir] ++
        env_args(Keyword.get(opts, :env, [])) ++
        [image, "sleep", "infinity"]

    case docker(args, opts) do
      {_id, 0} ->
        env = %Environment{type: :container, cwd: workdir, ref: %{container: name}}

        case mkdir_p(env, workdir, opts) do
          :ok -> {:ok, env}
          {:error, reason} -> {:error, reason}
        end

      {output, status} ->
        {:error, "could not start a container from #{image} (exit #{status}): #{trim(output)}"}
    end
  end

  @doc """
  Remove the container.

  Forced, and failure is logged rather than returned. A caller tearing down
  has nothing useful to do with the error, and a `destroy` that can fail the
  run it is cleaning up after turns one problem into two — but a container
  left running costs money quietly, so it is never silent.
  """
  @impl true
  def destroy(%Environment{} = env) do
    case docker(["rm", "--force", container(env)], []) do
      {_, 0} ->
        :ok

      {output, status} ->
        Logger.error(
          "[Container] could not remove #{container(env)} (exit #{status}): #{trim(output)} — " <>
            "it may still be running and billing"
        )

        :ok
    end
  end

  ## Commands

  @impl true
  def cmd(%Environment{} = env, command, args, opts \\ []) do
    cd = Keyword.get(opts, :cd) || env.cwd || @workdir

    exec =
      ["exec", "--workdir", cd] ++
        env_args(Keyword.get(opts, :env, [])) ++
        [container(env), command | args]

    docker(exec, opts)
  end

  @impl true
  def exec_file_exists?(%Environment{} = env, path) do
    match?({_, 0}, sh(env, "test -x #{shell_quote(resolve(env, path))}"))
  end

  ## Files

  @impl true
  def read_file(%Environment{} = env, path) do
    host = temp_path()

    try do
      case docker(["cp", "#{container(env)}:#{resolve(env, path)}", host], []) do
        {_, 0} -> File.read(host)
        {output, _} -> {:error, cp_reason(output, path)}
      end
    after
      File.rm(host)
    end
  end

  @impl true
  def write_file(%Environment{} = env, path, content) do
    host = temp_path()
    target = resolve(env, path)

    try do
      with :ok <- File.write(host, content),
           :ok <- mkdir_p(env, Path.dirname(target), []),
           {_, 0} <- docker(["cp", host, "#{container(env)}:#{target}"], []) do
        :ok
      else
        {:error, reason} -> {:error, reason}
        {output, status} -> {:error, "writing #{path} failed (exit #{status}): #{trim(output)}"}
      end
    after
      File.rm(host)
    end
  end

  @impl true
  def delete_file(%Environment{} = env, path) do
    case sh(env, "rm -f #{shell_quote(resolve(env, path))}") do
      {_, 0} -> :ok
      {output, status} -> {:error, "deleting #{path} failed (exit #{status}): #{trim(output)}"}
    end
  end

  @impl true
  def file_exists?(%Environment{} = env, path) do
    match?({_, 0}, sh(env, "test -e #{shell_quote(resolve(env, path))}"))
  end

  @impl true
  def ensure_dir(%Environment{} = env, path), do: mkdir_p(env, resolve(env, path), [])

  @impl true
  def list_directory(%Environment{} = env, path) do
    case sh(env, "ls -1A #{shell_quote(resolve(env, path))}") do
      {output, 0} -> {:ok, lines(output)}
      {output, _} -> {:error, cp_reason(output, path)}
    end
  end

  @impl true
  def glob(%Environment{} = env, pattern) do
    # `find` rather than the shell's own globbing: `**` needs globstar, which
    # is bash-only and off by default, and a pattern that silently matches
    # nothing is indistinguishable from a directory that is genuinely empty.
    {dir, name} = split_pattern(resolve(env, pattern))

    case sh(env, "find #{shell_quote(dir)} -type f -name #{shell_quote(name)} 2>/dev/null") do
      {output, 0} -> lines(output)
      _ -> []
    end
  end

  @impl true
  def stat(%Environment{} = env, path) do
    resolved = resolve(env, path)

    case sh(env, "stat -c '%s %Y' #{shell_quote(resolved)}") do
      {output, 0} ->
        case output |> String.trim() |> String.split(" ") do
          [size, mtime] ->
            {:ok, %{size: String.to_integer(size), mtime: String.to_integer(mtime)}}

          _ ->
            {:error, :enoent}
        end

      _ ->
        {:error, :enoent}
    end
  end

  @impl true
  def stream_files(%Environment{} = env, roots, _opts \\ []) do
    roots
    |> Enum.flat_map(fn root ->
      case sh(env, "find #{shell_quote(resolve(env, root))} -type f 2>/dev/null") do
        {output, 0} -> lines(output)
        _ -> []
      end
    end)
    |> Stream.map(fn path ->
      case read_file(env, path) do
        {:ok, content} -> {path, content}
        {:error, _} -> {path, nil}
      end
    end)
    |> Stream.reject(fn {_path, content} -> is_nil(content) end)
  end

  ## Setup / teardown commands

  @impl true
  def environment_setup_command(_env, _attrs), do: ""

  @impl true
  def docs_environment_teardown_command(_env, _attrs), do: ""

  @impl true
  def test_environment_teardown_command(_env, _attrs), do: ""

  @impl true
  def code_environment_teardown_command(_env, _attrs), do: ""

  ## Internals

  @doc "The container a given environment addresses."
  @spec container(Environment.t()) :: String.t()
  def container(%Environment{ref: %{container: name}}), do: name

  def container(%Environment{} = env) do
    raise ArgumentError,
          "#{inspect(env)} is not a container environment — its ref carries no container name"
  end

  defp docker(args, opts) do
    System.cmd("docker", args, stderr_to_stdout: Keyword.get(opts, :stderr_to_stdout, true))
  rescue
    e in ErlangError ->
      # `docker` missing is a deployment problem, and :enoent several frames
      # down says nothing about it.
      {"docker is not available on this host: #{inspect(e)}", 127}
  end

  defp sh(env, script), do: cmd(env, "sh", ["-c", script], [])

  defp mkdir_p(env, path, opts) do
    case cmd(env, "mkdir", ["-p", path], opts) do
      {_, 0} -> :ok
      {output, status} -> {:error, "could not create #{path} (exit #{status}): #{trim(output)}"}
    end
  end

  # Absolute paths are honoured; everything else is relative to the workdir,
  # which is what every step means when it says `bin/deploy` or `.sops.yaml`.
  defp resolve(%Environment{cwd: cwd}, path) do
    if String.starts_with?(path, "/"), do: path, else: Path.join(cwd || @workdir, path)
  end

  defp env_args(vars) do
    Enum.flat_map(vars, fn {key, value} -> ["--env", "#{key}=#{value}"] end)
  end

  defp split_pattern(pattern) do
    case String.split(pattern, "/**/") do
      [dir, name] -> {dir, name}
      _ -> {Path.dirname(pattern), Path.basename(pattern)}
    end
  end

  defp lines(output) do
    output |> String.split("\n", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp cp_reason(output, path) do
    if output =~ "No such file" or output =~ "not found", do: :enoent, else: "#{path}: #{trim(output)}"
  end

  defp trim(output), do: output |> to_string() |> String.trim()

  defp shell_quote(value), do: "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"

  defp temp_path do
    Path.join(System.tmp_dir!(), "cms-container-#{System.unique_integer([:positive])}")
  end

  defp generate_name, do: "cms-run-#{System.unique_integer([:positive])}"
end
