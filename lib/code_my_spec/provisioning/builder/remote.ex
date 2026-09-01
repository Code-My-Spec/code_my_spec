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

  require Logger

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

    # One line per phase — the only signal, short of SSHing in by hand, that
    # a build is still moving rather than stuck. Confirmed live: nothing here
    # logged anything between "started" and "done or failed", so a long real
    # build and a hung one were indistinguishable from the outside.
    with :ok <- await_ssh(run, Keyword.get(opts, :ssh_attempts, @ssh_attempts), opts),
         _ = Logger.info("[Builder] ssh reachable, delivering #{ref}"),
         :ok <- deliver_source(deliver, ref, dir, opts),
         _ = Logger.info("[Builder] source delivered, running docker build"),
         :ok <- docker_build(run, reference, ref, dir, opts),
         _ = Logger.info("[Builder] docker build finished, pushing #{reference}"),
         :ok <- maybe_push(run, reference, opts),
         _ = Logger.info("[Builder] pushed #{reference}, reading back its architecture"),
         {:ok, architecture} <- built_architecture(run, reference) do
      {:ok, %{reference: reference, architecture: architecture}}
    end
  end

  # Answering once is not staying up. A fresh box accepts SSH, then cloud-init
  # finishes and restarts sshd, and the next connection — this one, seconds
  # later — times out. The drill saw exactly that: `await_ssh/5` returned and
  # the archive died on "connect to host ...: Operation timed out".
  #
  # Exit 255 is ssh's own failure and nothing else's; any other status is the
  # remote `tar` or `rm` reporting, which must stay an immediate error rather
  # than being retried into a long silence.
  defp deliver_source(deliver, ref, dir, opts, attempts \\ 10) do
    case deliver.(ref, dir) do
      :ok ->
        :ok

      {:error, {:source_delivery_failed, 255, _}} when attempts > 1 ->
        Wait.sleep(Keyword.get(opts, :ssh_interval_ms, @ssh_interval_ms))
        deliver_source(deliver, ref, dir, opts, attempts - 1)

      other ->
        other
    end
  end

  @doc """
  Block until the box answers SSH, or give up saying how long it waited.

  Reachability, not readiness of anything in particular: if `true` runs, the
  box is up and the key works, which is the whole precondition.

  The give-up carries how long it waited and what SSH last said. A bare
  `:builder_unreachable` describes a broken box equally well as a caller who
  did not wait long enough, and those want opposite responses — the first
  needs looking at, the second needs patience.

  Public because the builder is not the only caller that needs it. A server
  Hetzner has just created answers `status: initializing` for a minute or so,
  and the registry step went straight from `POST /v1/servers` to running docker
  over SSH on the box — reaching it about thirty seconds in, timing out, and
  halting the whole run at `server` with every step behind it reporting
  nothing. That read as an address that had stopped being ours; it was our own
  box, still booting.
  """
  @spec await_ssh((list() -> {String.t(), non_neg_integer()}), non_neg_integer(), keyword()) ::
          :ok | {:error, {:builder_unreachable, non_neg_integer(), String.t()}}
  def await_ssh(run, attempts, opts, waited \\ 0, last \\ "")

  def await_ssh(_run, 0, _opts, waited, last) do
    {:error, {:builder_unreachable, div(waited, 1000), last}}
  end

  def await_ssh(run, attempts, opts, waited, _last) do
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
  Install kamal on the builder before it orchestrates a deploy over it,
  unless it is already there.

  Checked first rather than assumed either way: `Builder.custom_image?/1`
  builders come from a snapshot with kamal already baked in (built once by
  `Builder.ensure_builder_image/2`, exactly to skip this on every ordinary
  deploy), but the stock `docker-ce` fallback — used until that snapshot
  exists, or if it is ever unavailable — still needs it installed fresh
  every time. One `command -v` check makes this correct under both without
  the caller having to know which box it got.

  Ruby is not part of the `docker-ce` base image, and nothing installed it
  before one particular night: nothing had gotten a real harness-only
  project's deploy far enough to actually invoke `bin/deploy migrate` and
  find `kamal: command not found` (exit 127) — confirmed live against
  MarketMySpec, the first deploy through this path to get this far.

  `NEEDRESTART_MODE=a` is load-bearing, not decoration: installing
  `ruby-full` on a stock Debian image triggers `needrestart`'s own apt hook,
  and its default interactive mode prints a page of "Restarting
  services.../No containers need to be restarted" chatter ahead of whatever
  actually failed. `devops_status` reports a failure's first 300 characters
  — confirmed live, that chatter alone pushed the real error (a follow-up
  `apt-get`/`gem` failure) past the cutoff, reading as truncated nonsense
  instead of a cause. `-y` alone does not suppress it; needrestart reads its
  own env var.

  `build-essential` is there for `ed25519` — a native-extension gem `kamal`
  pulls in transitively through `net-ssh`, whose `extconf`/`mkmf` step needs
  a C toolchain to compile against. `ruby-full`'s own dependency chain does
  not pull that in on Debian: confirmed live, the very next failure once
  `ruby-full` alone installed cleanly was `mkmf.log`/`extconf failed`.
  """
  @spec ensure_kamal((list() -> {String.t(), non_neg_integer()})) ::
          :ok | {:error, {non_neg_integer(), String.t()}}
  def ensure_kamal(run) do
    case run.(["command -v kamal"]) do
      {_, 0} -> :ok
      _ -> install_kamal(run)
    end
  end

  defp install_kamal(run) do
    command =
      "apt-get update -qq && " <>
        "DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a " <>
        "apt-get install -y -qq ruby-full build-essential >/dev/null && " <>
        "gem install kamal --no-document"

    case run.([command]) do
      {_, 0} -> :ok
      # The tail, not the head: `devops_status` keeps only the first 300
      # characters of whatever reason this becomes, and apt/gem both put
      # their actual failure at the end of their output, after everything
      # that went fine. The head is the least useful part to keep.
      {output, status} -> {:error, {status, output |> trim() |> String.slice(-300, 300)}}
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
  Deliver `ref`'s tree straight from GitHub, for a project whose real
  checkout `ssh_deliver/2` cannot reach.

  `ssh_deliver/2`'s own reasoning for archiving from the project's own
  environment — no GitHub credential anywhere near the builder — assumes
  there is a reachable environment to archive from. A harness-only project's
  `scope.environment` is not one (`Environment.new(:local, nil)`, the same
  shape `Steps.head_commit/1` already falls back for), so there is nothing
  to run `git archive` against; the source has to come from somewhere the
  builder itself can already reach. GitHub is that somewhere, since setup
  already pushed the project there.

  Runs entirely over the same SSH `ssh_deliver/2` uses — the credential
  travels with this one request, not as a file or a git remote the builder
  keeps. `--location-trusted` is needed and safe here specifically because
  the API's tarball endpoint always redirects to `codeload.github.com`: `-u`
  credentials are stripped on a cross-host redirect otherwise, and a private
  repository's tarball 404s on the redirected request without them.
  `--strip-components=1` matches `git archive`'s output — the API wraps the
  tree in a single `owner-repo-sha/` directory `git archive` never adds.
  """
  @spec github_deliver(map(), keyword()) :: (String.t(), String.t() -> :ok | {:error, term()})
  def github_deliver(server, opts) do
    run = Keyword.get(opts, :run) || ssh_runner(server, opts)
    repo = Keyword.fetch!(opts, :github_repo)
    token = Keyword.fetch!(opts, :github_token)

    fn ref, dir ->
      command =
        "rm -rf #{dir} && mkdir -p #{dir} && " <>
          "curl -sSfL --location-trusted -u #{shell_quote("x-access-token:#{token}")} " <>
          "https://api.github.com/repos/#{repo}/tarball/#{ref} | " <>
          "tar -xz -C #{dir} --strip-components=1"

      case run.([command]) do
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
  defp docker_build(run, reference, ref, dir, opts) do
    labels = "--label commit=#{ref}" <> service_label(Keyword.get(opts, :service))
    flags = labels <> platform_flag(Keyword.get(opts, :platform))

    case run.(["cd #{dir} && docker build #{flags} -t #{reference} ."]) do
      {_, 0} -> :ok
      {output, status} -> {:error, {:build_failed, status, trim(output)}}
    end
  end

  # NEVER set this in production, and the reason is the opposite of the usual
  # one: it would work.
  #
  # `Builder` refuses to publish an image whose architecture is not the one the
  # servers run, and that refusal is load-bearing — a mismatched image starts
  # and dies at the swap, long after the deploy looks like it is going well. In
  # production the architecture is an *input*: the builder box is created as the
  # same type as the app's box, so what comes out is what that box is, and a
  # mismatch means something upstream picked wrong. Forcing the platform would
  # make Docker emulate its way to the right answer and the check would never
  # fire again — the guard would still be there, still be green, and never
  # catch anything.
  #
  # It exists for the local fleet, where a single box has to stand in for boxes
  # of both architectures. That is a property of the fixture, not of the build.
  defp platform_flag(nil), do: ""
  defp platform_flag(platform), do: " --platform #{platform}"

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

        with :ok <- trust(run, host),
             :ok <- login(run, reference, opts) do
          docker_push(run, reference)
        end
    end
  end

  # The result used to be discarded, and the cost of that was paid in the wrong
  # place: when the trust step fails the push fails too, with `server gave HTTP
  # response to HTTPS client`, which describes the registry rather than the
  # thing that actually went wrong on this box. Naming it here means the next
  # reader is told the daemon was never reconfigured instead of being pointed
  # at a registry that is behaving correctly.
  #
  # `trust_command/1` is a no-op when the host is already trusted, so this is
  # only ever reached on a box that had to be changed.
  defp trust(run, host) do
    case loopback?(host) do
      true -> :ok
      false -> attempt_trust(run, host)
    end
  end

  defp attempt_trust(run, host) do
    case run.([CodeMySpec.Provisioning.Registry.trust_command(host)]) do
      {_, 0} -> :ok
      {output, status} -> {:error, {:registry_trust_failed, host, status, trim(output)}}
    end
  end

  # Docker already treats a loopback registry as insecure — that is its own
  # rule, not ours — so there is nothing to configure and no daemon to restart.
  # Which makes the write worse than pointless there: the local build path runs
  # as whoever is running the tests, and `mkdir /etc/docker` on a developer's
  # machine is a permission error at best and an edit to their real daemon at
  # worst.
  defp loopback?(host) do
    address = host |> String.split(":") |> hd()
    address == "localhost" or String.starts_with?(address, "127.")
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
      {_, 0} ->
        :ok

      {output, status} ->
        {:error, {:push_failed, status, trim(output) <> where_am_i(run, reference)}}
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

    {port, _} =
      run.(["timeout 5 bash -c '</dev/tcp/#{address}/5000' && echo OPEN || echo CLOSED"])

    {http, _} = run.(["curl -sv --max-time 5 http://#{host}/v2/ 2>&1 | tail -8"])

    "\n\nbuilder interfaces:\n" <>
      trim(addresses) <>
      "\n\nping #{address}:\n" <>
      trim(ping) <>
      "\n\ntcp #{address}:5000: " <>
      trim(port) <>
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

    ssh_port(Keyword.get(opts, :ssh_port)) ++
      [
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        # `UserKnownHostsFile=/dev/null` throws every host away as soon as it is
        # written, so ssh can never find one already saved and prints "Warning:
        # Permanently added ... to the list of known hosts" on *every* call, not
        # just the first. `ssh_runner/2` merges that onto stdout
        # (`stderr_to_stdout: true`), so a caller checking "is the output empty"
        # was never looking at the command's own output — `container_running?`
        # in both `Database` and `Registry` read this banner as "yes, something
        # is there" unconditionally, on a box with nothing running at all.
        # Confirmed live against fuellytics-prod: `cms-registry` never got
        # created — not even attempted, `docker images`/`docker ps -a` and
        # dockerd's own journal show no trace of it — because this is why
        # `ensure_container/5` believed a fresh box already had one. Silencing
        # the banner at the source fixes every current and future caller that
        # parses this output, not just the two callers found tonight.
        "-o",
        "LogLevel=ERROR",
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
        # Without this, an address that answers nothing costs the OS default —
        # around 75 seconds per attempt on macOS — and the caller has no way to
        # shorten it. A box we just created either answers quickly or is not
        # ready, and the callers that care already poll (`await_ssh/5` makes 90
        # attempts), so a long single attempt buys nothing and delays the retry
        # that would have succeeded.
        #
        # Measured: two such attempts were 150 of the 304 seconds a single spex
        # story spent, against server addresses that stopped being ours weeks
        # ago.
        "-o",
        "ConnectTimeout=10",
        "-i",
        key,
        "root@#{ip(server)}"
      ]
  end

  # A cloud box is always on 22, so this is absent in production and the flags
  # are byte-identical to what they were. It exists for the local fleet, where
  # boxes are containers reached on published loopback ports — and the point of
  # that fleet is to run *this* function rather than a local imitation of it,
  # so the one thing it cannot do is fork the command it builds.
  defp ssh_port(nil), do: []
  defp ssh_port(port), do: ["-p", to_string(port)]

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
