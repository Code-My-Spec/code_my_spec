defmodule CodeMySpec.Provisioning.Builder.Remote do
  @moduledoc """
  Run the build on the builder box.

  Separate from `Builder` because they answer different questions. `Builder`
  owns the box's existence — created for one build, destroyed either way.
  This owns what happens while it exists: reach it, fetch the commit, build,
  push, and read back what was actually built.

  That last step is the one worth defending. `Builder` refuses to publish an
  image whose architecture is not the one the servers run, and that check is
  worth nothing if this simply echoes back the architecture it was asked for.
  So the architecture is read off the built image, and a build that quietly
  produced the wrong one is caught by the check rather than waved through it.
  """

  alias CodeMySpec.Environments
  alias CodeMySpec.Provisioning.Wait

  # A freshly created box answers the API long before it answers SSH. Polled
  # rather than slept-through, so a box that comes up quickly is not waited on
  # for the worst case.
  #
  # Three minutes, not one. Sixty seconds is inside the range a cold Hetzner
  # box takes to reach sshd, so it was a coin toss: one drill delivered its
  # source and started building, the next reported `builder unreachable` doing
  # nothing differently. Waiting costs nothing when the box is quick, because
  # this polls — and the failure it produces is expensive, since it reads as a
  # broken builder rather than an impatient caller.
  @ssh_attempts 90
  @ssh_interval_ms 2_000

  @doc """
  Build `ref` on `server` and push it to `reference`.

  `:run` takes the whole command as a list and returns `{output, status}`,
  which is what makes this testable without a box: the commands are the
  interesting part, and running them is not.
  """
  @spec build(map(), String.t(), String.t(), keyword()) ::
          {:ok, %{reference: String.t(), architecture: :arm | :x86}} | {:error, term()}
  def build(server, ref, reference, opts \\ []) do
    run = Keyword.get(opts, :run) || ssh_runner(server, opts)
    deliver = Keyword.get(opts, :deliver) || ssh_deliver(server, opts)

    dir = Keyword.get(opts, :build_dir, "/build")

    with :ok <- await_ssh(run, Keyword.get(opts, :ssh_attempts, @ssh_attempts), opts),
         :ok <- deliver.(ref, dir),
         :ok <- docker_build(run, reference, ref, dir, Keyword.get(opts, :service)),
         :ok <- maybe_push(run, reference, opts),
         {:ok, architecture} <- built_architecture(run, reference) do
      {:ok, %{reference: reference, architecture: architecture}}
    end
  end

  # Reachability, not readiness of anything in particular: if `true` runs, the
  # box is up and the key works, which is the whole precondition.
  #
  # The give-up carries how long it waited and what SSH last said. A bare
  # `:builder_unreachable` describes a broken box equally well as a caller who
  # did not wait long enough, and those want opposite responses — the first
  # needs looking at, the second needs patience.
  defp await_ssh(run, attempts, opts, waited \\ 0, last \\ "")

  defp await_ssh(_run, 0, _opts, waited, last) do
    {:error, {:builder_unreachable, div(waited, 1000), last}}
  end

  defp await_ssh(run, attempts, opts, waited, _last) do
    case run.(["true"]) do
      {_, 0} ->
        :ok

      {output, _status} ->
        interval = Keyword.get(opts, :ssh_interval_ms, @ssh_interval_ms)
        Wait.sleep(interval)
        await_ssh(run, attempts - 1, opts, waited + interval, trim(output))
    end
  end

  @doc """
  Send one commit's tree to the builder, over the SSH we already have.

  The builder used to clone from GitHub. Repositories are created private
  (`Repository`, `private: true` by default) and setup installs no deploy key,
  so it could not have worked — and it never ran, because the step died
  earlier on a missing `:env` before it got this far.

  Three ways out of that were on the table: a deploy key on the repository, a
  token in the clone URL, or this. This one is chosen because it leaves no
  GitHub credential anywhere near the builder — a box that exists for one
  build, that we do not exclusively control while it lives, and whose shell
  history and git config would otherwise hold a token. We already hold SSH to
  it, so there is nothing to add.

  `git archive` rather than a clone, so what lands is exactly the commit's
  tree: no history, no remotes, no `.git`, and nothing to leak. Shallow
  cloning was the old optimisation for the same reason — the builder does not
  need the history — and this is that argument taken to its end.
  """
  @spec ssh_deliver(map(), keyword()) :: (String.t(), String.t() -> :ok | {:error, term()})
  def ssh_deliver(server, opts) do
    env = Keyword.fetch!(opts, :env)

    fn ref, dir ->
      remote = "rm -rf #{dir} && mkdir -p #{dir} && tar -x -C #{dir}"

      command =
        "git archive --format=tar #{ref} | " <>
          Enum.join(["ssh" | ssh_args(server, opts)], " ") <>
          " " <> shell_quote(remote)

      # Through the project's own environment, so the archive is taken from
      # the checkout the deploy is for rather than from wherever the server
      # happens to be running.
      case Environments.cmd(env, "sh", ["-c", command], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {output, status} -> {:error, {:source_delivery_failed, status, trim(output)}}
      end
    end
  end

  @doc """
  Deliver into a directory on this machine, for the local build path.

  `:cd` is the checkout to archive from. Pairs with `local_runner/1` the way
  `ssh_deliver/2` pairs with `ssh_runner/2`.
  """
  @spec local_deliver(keyword()) :: (String.t(), String.t() -> :ok | {:error, term()})
  def local_deliver(opts) do
    cd = Keyword.fetch!(opts, :cd)

    fn ref, dir ->
      command =
        "rm -rf #{dir} && mkdir -p #{dir} && git archive --format=tar #{ref} | tar -x -C #{dir}"

      case System.cmd("sh", ["-c", command], cd: cd, stderr_to_stdout: true) do
        {_, 0} -> :ok
        {output, status} -> {:error, {:source_delivery_failed, status, trim(output)}}
      end
    end
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  # `service` is kamal's, and it refuses an image without it:
  #
  #   Image <ref> is missing the 'service' label
  #
  # kamal builds its own images and stamps the label itself. Setup builds on
  # its own builder and deploys with `--skip-push`, so nothing else was ever
  # going to add it — the pull succeeded and the very next command rejected
  # what it had just pulled.
  defp docker_build(run, reference, ref, dir, service) do
    labels = "--label commit=#{ref}" <> service_label(service)

    case run.(["cd #{dir} && docker build #{labels} -t #{reference} ."]) do
      {_, 0} -> :ok
      {output, status} -> {:error, {:build_failed, status, trim(output)}}
    end
  end

  defp service_label(service) when is_binary(service) and service != "",
    do: " --label service=#{shell_quote(service)}"

  defp service_label(_service), do: ""

  # Skippable, because a registry is the one thing a local build cannot stand
  # in for — pushing to a real one would turn a build test into a network test.
  # Never skipped in production: the deploy pulls what was pushed.
  defp maybe_push(run, reference, opts) do
    case Keyword.get(opts, :push, true) do
      false ->
        :ok

      _ ->
        # Docker assumes HTTPS for anything but `localhost`, and the registry
        # on the project's private network speaks plain HTTP. Without this the
        # push fails with `context deadline exceeded` — a timeout, which reads
        # as an unreachable host rather than a protocol disagreement.
        host = reference |> String.split("/") |> hd()
        run.([CodeMySpec.Provisioning.Registry.trust_command(host)])

        with :ok <- login(run, reference, opts), do: docker_push(run, reference)
    end
  end

  # A registry on a public hostname must not accept anonymous writes, and this
  # pushed with no credential at all — so the push could only ever have
  # succeeded against a registry that let anyone write to it. Nothing had
  # noticed because nothing had reached a real push yet.
  #
  # The credential is the registry's, not the project's: one shared registry
  # (see `Provisioning.Registry`), so it comes from our config rather than from
  # `ProjectSecrets`. Absent credentials stay a no-op, which keeps every
  # existing test and any local unauthenticated registry working.
  #
  # `--password-stdin` rather than `-p`: the password would otherwise be in the
  # builder's shell history and in the process list of a box we do not own for
  # long, but do not own alone either.
  defp login(run, reference, opts) do
    case Keyword.get(opts, :registry_credentials) || configured_credentials() do
      %{username: username, password: password}
      when is_binary(username) and is_binary(password) ->
        host = reference |> String.split("/") |> hd()

        command =
          "printf %s #{shell_escape(password)} | " <>
            "docker login #{shell_escape(host)} " <>
            "--username #{shell_escape(username)} --password-stdin"

        case run.([command]) do
          {_, 0} -> :ok
          {output, status} -> {:error, {:login_failed, status, trim(output)}}
        end

      _ ->
        :ok
    end
  end

  defp configured_credentials do
    config = Application.get_env(:code_my_spec, CodeMySpec.Provisioning.Registry, [])

    case {config[:username], config[:password]} do
      {username, password} when is_binary(username) and is_binary(password) ->
        %{username: username, password: password}

      _ ->
        nil
    end
  end

  # Single quotes, with any embedded quote closed and reopened. The password is
  # generated rather than typed, but a shell-quoting bug here fails as a login
  # error that names nothing, which is the hardest kind to read.
  defp shell_escape(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  defp docker_push(run, reference) do
    case run.(["docker push #{reference}"]) do
      {_, 0} -> :ok
      {output, status} -> {:error, {:push_failed, status, trim(output) <> where_am_i(run, reference)}}
    end
  end

  # A push that times out says nothing about why. The registry answers on the
  # project's private network, so the first question is whether this box is on
  # it — and the box is destroyed with the build, so asking afterwards is not
  # an option. Cheap enough to always attach, and only ever read on failure.
  defp where_am_i(run, reference) do
    host = reference |> String.split("/") |> hd()
    address = host |> String.split(":") |> hd()

    {addresses, _} = run.(["ip -4 -o addr show | awk '{print $2, $4}'"])

    # Three questions, narrowest first: does the host answer at all, is the
    # port open, and what does an HTTP request actually do. A timeout on the
    # push says none of them, and the box is destroyed with the build.
    {ping, _} = run.(["ping -c2 -W2 #{address} 2>&1 | tail -3"])
    {port, _} = run.(["timeout 5 bash -c '</dev/tcp/#{address}/5000' && echo OPEN || echo CLOSED"])
    {http, _} = run.(["curl -sv --max-time 5 http://#{host}/v2/ 2>&1 | tail -8"])

    "\n\nbuilder interfaces:\n" <> trim(addresses) <>
      "\n\nping #{address}:\n" <> trim(ping) <>
      "\n\ntcp #{address}:5000: " <> trim(port) <>
      "\n\nhttp #{host}/v2/:\n" <> trim(http)
  end

  # Read, not assumed. `Builder` refuses to ship an image built for the wrong
  # architecture, and that refusal only means something if this reports what
  # the image actually is.
  defp built_architecture(run, reference) do
    case run.(["docker image inspect --format '{{.Architecture}}' #{reference}"]) do
      {output, 0} -> output |> last_line() |> architecture()
      {output, status} -> {:error, {:inspect_failed, status, trim(output)}}
    end
  end

  # The answer is the last line, not the whole output. Commands run over SSH
  # with stderr folded into stdout, and ssh writes its own
  # `Warning: Permanently added ... to the list of known hosts.` there — so a
  # command whose output we parse gets that warning glued to the front. It read
  # as `{:unknown_architecture, "Warning: ...\namd64"}`: a real amd64 image,
  # refused because the architecture check was shown a greeting.
  defp last_line(output) do
    output
    |> to_string()
    |> String.split("\n", trim: true)
    |> List.last("")
    |> String.trim()
  end

  defp architecture("arm64"), do: {:ok, :arm}
  defp architecture("aarch64"), do: {:ok, :arm}
  defp architecture("amd64"), do: {:ok, :x86}
  defp architecture("x86_64"), do: {:ok, :x86}
  defp architecture(other), do: {:error, {:unknown_architecture, other}}

  # One SSH invocation per command, which is slower than holding a session open
  # and much easier to reason about: every command is independently visible in
  # a log and independently replaceable in a test.
  @doc """
  Run commands on a box over SSH.

  Public because the builder is not the only thing that has to reach a server
  it just provisioned — the registry has to be started on the app's own box,
  and that is the same question with a different address. Duplicating the flag
  set was the alternative, and `IdentitiesOnly` is exactly the kind of thing
  one copy learns and the other does not.
  """
  @spec ssh_runner(map(), keyword()) :: (list() -> {String.t(), non_neg_integer()})
  def ssh_runner(server, opts) do
    env = Keyword.fetch!(opts, :env)
    args = ssh_args(server, opts)

    fn [command] ->
      Environments.cmd(env, "ssh", args ++ [command], stderr_to_stdout: true)
    end
  end

  # Shared by the runner and by `ssh_deliver/2`, which reaches the same box on
  # the same terms. Two copies of these flags would be two things to keep in
  # step, and the failure of drift is an authentication error on one of the
  # two paths that says nothing about why the other one works.
  defp ssh_args(server, opts) do
    key = Keyword.fetch!(opts, :ssh_key_path)

    [
      "-o",
      "StrictHostKeyChecking=no",
      "-o",
      "UserKnownHostsFile=/dev/null",
      # Without these, `-i` is a suggestion: ssh offers every key the agent
      # holds first, and a box with the default `MaxAuthTries 6` disconnects
      # before reaching ours. `Servers.Containers` already learned this and
      # says so; the builder did not, and paid for it — three minutes of
      # retrying, then "Too many authentication failures", which the caller
      # reported as an unreachable box. I raised the SSH timeout over it before
      # reading the message, and the box had been answering all along.
      "-o",
      "BatchMode=yes",
      "-o",
      "IdentitiesOnly=yes",
      "-i",
      key,
      "root@#{ip(server)}"
    ]
  end

  @doc """
  A runner that uses the local machine instead of a box.

  The same command sequence, the same real `docker build`, no cloud and no
  SSH — which makes the interesting half of this module exercisable without
  provisioning anything. What it does not exercise is the box: reachability,
  the pre-warmed image, and destruction still need the real thing.
  """
  @spec local_runner(keyword()) :: (list() -> {String.t(), non_neg_integer()})
  def local_runner(opts) do
    # Required rather than defaulted to the current directory. The sequence this
    # runs starts with `rm -rf`, and a caller who forgot to say where should get
    # an error rather than have it aimed at whatever repository happens to be
    # open.
    cd = Keyword.fetch!(opts, :cd)

    fn [command] -> System.cmd("sh", ["-c", command], cd: cd, stderr_to_stdout: true) end
  end

  defp ip(%{"public_net" => %{"ipv4" => %{"ip" => ip}}}), do: ip
  defp ip(%{"server" => server}), do: ip(server)
  defp ip(%{"ip" => ip}), do: ip

  defp trim(output), do: output |> to_string() |> String.trim()
end
