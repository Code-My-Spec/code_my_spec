defmodule CodeMySpec.Provisioning.FleetBuildTest do
  @moduledoc """
  Build on the local fleet, over SSH, and push to a registry.

  This is `Builder.Remote.build/4` unmodified — the same `ssh_runner/2`, the
  same `ssh_deliver/2` piping `git archive` into `tar`, the same `docker build`
  and the same push. What changes is where the box comes from: a container on
  loopback instead of a slot on a five-server account.

  That distinction is the whole point. A cassette cannot tell "this works" from
  "this has never run", and most of this epic's defects were the second kind —
  `ssh_deliver` cloning a private repo with no credential, an image missing the
  `service` label kamal requires, a push to a plain-HTTP registry read as a
  network timeout. Each was one ten-minute cloud drill to find, and each would
  have been a second here.

  Excluded by default (`:fleet`), because it needs the fleet running:

      docker/fleet/fleet.sh up
      mix test --only fleet
  """
  use ExUnit.Case, async: false

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Provisioning.Builder.Remote

  @moduletag :fleet
  # A cold `docker build` inside a box whose daemon has an empty image store
  # pulls its base layers first. Generous on purpose: the failure of a tight
  # timeout here is an unexplained flake that reads as a broken builder.
  @moduletag timeout: 600_000

  @key Path.expand("../../../docker/fleet/keys/fleet", __DIR__)
  @builder %{"ip" => "127.0.0.1"}

  setup do
    assert File.exists?(@key), "no fleet key at #{@key} — run docker/fleet/fleet.sh up"

    :ok
  end

  describe "building on a fleet box" do
    @tag :fleet
    test "delivers a commit, builds it, and reads back the architecture it really built" do
      # A tree with a Dockerfile and a commit to archive, because `ssh_deliver`
      # sends `git archive <ref>` — there has to be a real ref holding a real
      # tree, not a directory.
      source = tmp_repo()

      opts = [
        env: Environment.new(:local, source),
        ssh_key_path: @key,
        ssh_port: 2222,
        service: "fleet-test",
        # The registry is on the fleet network under that name, which is the
        # same private-network shape a provisioned registry has.
        push: false
      ]

      reference = "registry:5000/fleet-test:#{commit(source)}"

      assert {:ok, %{reference: ^reference, architecture: architecture}} =
               Remote.build(@builder, commit(source), reference, opts)

      # Read off the image rather than echoed back — the check `Builder` makes
      # is worthless if this reports what it was asked for.
      assert architecture in [:arm, :x86]
    end

    @tag :fleet
    test "labels the image with the service kamal requires" do
      # kamal refuses an image without it — `Image <ref> is missing the
      # 'service' label` — and it refuses *after* pulling, so the failure
      # arrives at deploy time on a box that has already done all the work.
      source = tmp_repo()
      ref = commit(source)
      reference = "registry:5000/fleet-label:#{ref}"

      assert {:ok, _} =
               Remote.build(@builder, ref, reference,
                 env: Environment.new(:local, source),
                 ssh_key_path: @key,
                 ssh_port: 2222,
                 service: "fleet-label",
                 push: false
               )

      assert "fleet-label" == inspect_label(reference, "service")
      assert ref == inspect_label(reference, "commit")
    end
  end

  describe "pushing to the fleet registry" do
    @tag :fleet
    test "trusts a plain-HTTP registry and pushes to it" do
      # The registry answers HTTP, and Docker assumes HTTPS for anything but
      # localhost. Without `trust_command/1` this fails as `context deadline
      # exceeded` — a timeout, which reads as an unreachable host rather than a
      # protocol disagreement, and sent one drill looking at firewalls.
      #
      # A mounted host socket could not test this at all: the daemon.json edit
      # would land in a container that owns no daemon. The box runs its own.
      source = tmp_repo()
      ref = commit(source)
      reference = "registry:5000/fleet-push:#{ref}"

      assert {:ok, _} =
               Remote.build(@builder, ref, reference,
                 env: Environment.new(:local, source),
                 ssh_key_path: @key,
                 ssh_port: 2222,
                 service: "fleet-push",
                 push: true
               )

      # Asked of the registry, not of the builder: the builder believing it
      # pushed is what we are checking, so it does not get to be the witness.
      {body, 0} =
        System.cmd("curl", ["-s", "http://127.0.0.1:5010/v2/fleet-push/tags/list"],
          stderr_to_stdout: true
        )

      assert body =~ ref
    end
  end

  defp tmp_repo do
    dir = CodeMySpec.TempFile.dir("fleet-build")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    # Smallest thing that is genuinely built: scratch with one file. The
    # question here is whether the pipeline runs, not whether Docker can
    # compile Elixir.
    File.write!(Path.join(dir, "Dockerfile"), "FROM alpine:3.20\nRUN echo fleet > /fleet\n")

    {_, 0} = git(dir, ["init", "-q"])
    {_, 0} = git(dir, ["config", "user.email", "fleet@example.com"])
    {_, 0} = git(dir, ["config", "user.name", "Fleet"])
    {_, 0} = git(dir, ["add", "."])
    {_, 0} = git(dir, ["commit", "-q", "-m", "fleet"])

    dir
  end

  defp commit(dir) do
    {sha, 0} = git(dir, ["rev-parse", "HEAD"])
    String.trim(sha)
  end

  defp git(dir, args), do: System.cmd("git", args, cd: dir, stderr_to_stdout: true)

  defp inspect_label(reference, label) do
    {output, 0} =
      System.cmd(
        "ssh",
        ssh_flags() ++
          [
            "root@127.0.0.1",
            "docker image inspect --format '{{index .Config.Labels \"#{label}\"}}' #{reference}"
          ],
        stderr_to_stdout: true
      )

    # Last line, not the whole output: ssh writes its known-hosts warning to
    # the stderr we folded in, and gluing that to the front of a parsed answer
    # is a mistake this module's subject already made once.
    output |> String.split("\n", trim: true) |> List.last() |> String.trim()
  end

  defp ssh_flags do
    [
      "-o",
      "StrictHostKeyChecking=no",
      "-o",
      "UserKnownHostsFile=/dev/null",
      "-o",
      "BatchMode=yes",
      "-o",
      "IdentitiesOnly=yes",
      "-p",
      "2222",
      "-i",
      @key
    ]
  end
end
