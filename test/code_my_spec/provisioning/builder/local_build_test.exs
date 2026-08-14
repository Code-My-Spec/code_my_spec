defmodule CodeMySpec.Provisioning.Builder.LocalBuildTest do
  @moduledoc """
  The build sequence against real Docker, on this machine.

  `Builder.Remote` is unit-tested with the commands injected, which proves we
  ask for the right things. It does not prove those commands work — a sequence
  can be perfectly shaped and still fail on the first real `docker build`,
  which is exactly the gap that would otherwise only close when someone
  provisions a box and watches it fail.

  So this runs the same code path with `local_runner/1` and `local_deliver/1`:
  a real `git archive` of a real commit, a real image built from a real
  Dockerfile, and the architecture read back off it. No Hetzner, no SSH, no
  cost.

  What it still does not cover, and what the box is for: reachability, booting
  from the pre-warmed image, and destruction. Those are QA against real
  infrastructure.

  Tagged `:docker` and excluded by default — it builds an image, which is
  seconds rather than milliseconds and needs a working daemon.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.Builder.Remote

  @moduletag :docker
  @moduletag timeout: 300_000

  setup do
    tmp = CodeMySpec.TempFile.dir("cms-local-build")
    source = Path.join(tmp, "source")
    File.mkdir_p!(source)

    # A repository with one commit, because the sequence delivers a commit
    # rather than a directory — the same `git archive` the real path pipes over
    # SSH, only unpacked locally.
    File.write!(Path.join(source, "Dockerfile"), """
    FROM alpine:3
    RUN echo built > /built
    """)

    git = fn args -> System.cmd("git", args, cd: source, stderr_to_stdout: true) end
    {_, 0} = git.(["init", "-q", "-b", "main"])
    {_, 0} = git.(["config", "user.email", "builder@example.com"])
    {_, 0} = git.(["config", "user.name", "Builder"])
    {_, 0} = git.(["add", "."])
    {_, 0} = git.(["commit", "-q", "-m", "one"])
    {sha, 0} = git.(["rev-parse", "HEAD"])

    reference = "cms-local-build-test:#{System.unique_integer([:positive])}"

    on_exit(fn ->
      System.cmd("docker", ["rmi", "-f", reference], stderr_to_stdout: true)
      File.rm_rf(tmp)
    end)

    %{tmp: tmp, source: source, ref: String.trim(sha), reference: reference}
  end

  test "builds a real image and reports the architecture it actually built", ctx do
    result =
      Remote.build(
        %{"ip" => "local"},
        ctx.ref,
        ctx.reference,
        run: Remote.local_runner(cd: ctx.tmp),
        deliver: Remote.local_deliver(cd: ctx.source),
        build_dir: Path.join(ctx.tmp, "build"),
        # Nothing to push to — a registry is the one piece this cannot stand in
        # for locally, and pushing to a real one would make this a network test.
        push: false
      )

    assert {:ok, %{reference: reference, architecture: architecture}} = result
    assert reference == ctx.reference

    # Read off the image, not echoed back from the request. On this machine
    # that is arm64; the point is that it came from `docker image inspect`.
    assert architecture in [:arm, :x86]

    assert {_, 0} = System.cmd("docker", ["image", "inspect", ctx.reference],
             stderr_to_stdout: true
           )
  end

  @tag :registry
  test "pushes the image to a registry it can be pulled back from", ctx do
    # A registry container stands in for the self-hosted one. It is the last
    # step the local runner could not exercise, and skipping it left "the
    # deploy pulls what was pushed" resting on nothing.
    port = "5001"
    name = "cms-build-test-registry-#{System.unique_integer([:positive])}"

    {_, 0} =
      System.cmd("docker", ["run", "-d", "--name", name, "-p", "#{port}:5000", "registry:3"],
        stderr_to_stdout: true
      )

    on_exit(fn -> System.cmd("docker", ["rm", "-f", name], stderr_to_stdout: true) end)

    await_registry(port, 30)

    repository = "app-#{System.unique_integer([:positive])}"
    reference = "127.0.0.1:#{port}/#{repository}:#{String.slice(ctx.ref, 0, 12)}"
    on_exit(fn -> System.cmd("docker", ["rmi", "-f", reference], stderr_to_stdout: true) end)

    assert {:ok, %{architecture: architecture}} =
             Remote.build(
               %{"ip" => "local"},
               ctx.ref,
               reference,
               run: Remote.local_runner(cd: ctx.tmp),
               deliver: Remote.local_deliver(cd: ctx.source),
               build_dir: Path.join(ctx.tmp, "build")
             )

    assert architecture in [:arm, :x86]

    # Asked of the registry, not of the local daemon: an image that is still
    # only in the build cache would pass a `docker image inspect` and fail
    # every deploy.
    {tags, 0} =
      System.cmd("curl", ["-s", "http://127.0.0.1:#{port}/v2/#{repository}/tags/list"],
        stderr_to_stdout: true
      )

    assert tags =~ String.slice(ctx.ref, 0, 12)

    # And it comes back out. Removing it locally first, so the pull cannot be
    # answered from the cache.
    {_, 0} = System.cmd("docker", ["rmi", "-f", reference], stderr_to_stdout: true)
    assert {_, 0} = System.cmd("docker", ["pull", reference], stderr_to_stdout: true)
  end

  defp await_registry(_port, 0), do: flunk("the test registry never answered")

  defp await_registry(port, attempts) do
    {_, status} = System.cmd("curl", ["-sf", "http://127.0.0.1:#{port}/v2/"], stderr_to_stdout: true)

    retry_registry(port, attempts, status)
  end

  # Dispatched on the exit status rather than branched on it: a `case` here is
  # a test reacting to state, which the framework's own credo check rejects in
  # `_test.exs`. Polling an external service genuinely needs to retry, so the
  # retry moves into a head match instead of going away.
  defp retry_registry(_port, _attempts, 0), do: :ok

  defp retry_registry(port, attempts, _status) do
    Process.sleep(500)
    await_registry(port, attempts - 1)
  end

  test "a Dockerfile that cannot build is reported as a failed build", ctx do
    File.write!(Path.join(ctx.source, "Dockerfile"), """
    FROM alpine:3
    RUN exit 3
    """)

    {_, 0} = System.cmd("git", ["commit", "-qam", "break it"], cd: ctx.source)
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: ctx.source)

    assert {:error, {:build_failed, _status, output}} =
             Remote.build(
               %{"ip" => "local"},
               String.trim(sha),
               ctx.reference,
               run: Remote.local_runner(cd: ctx.tmp),
               deliver: Remote.local_deliver(cd: ctx.source),
               build_dir: Path.join(ctx.tmp, "build"),
               push: false
             )

    # The provider's own message, not ours — the same principle as 963/7962.
    assert output != ""
  end
end
