defmodule CodeMySpec.Provisioning.Builder.RemoteTest do
  @moduledoc """
  What the builder runs on the box, without a box.

  `:run` takes the command and returns `{output, status}`, so the commands are
  assertable and running them is not. That is the whole reason this is a unit
  test: a real `docker build` is minutes, non-deterministic, and invalidated by
  any Dockerfile edit — none of which tells us whether we asked for the right
  thing.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.Builder.Remote

  # Answers every command successfully and records what it was asked, so a test
  # can assert on the sequence rather than on a mock's expectations.
  defp recorder(owner, responses) do
    fn [command] ->
      send(owner, {:ran, command})

      Enum.find_value(responses, {"", 0}, fn {pattern, response} ->
        String.contains?(command, pattern) && response
      end)
    end
  end

  defp opts(run, overrides \\ []) do
    Keyword.merge(
      [run: run, deliver: recording_deliver(self()), ssh_interval_ms: 0],
      overrides
    )
  end

  # Source delivery is no longer one of the `run` commands — the builder does
  # not clone any more, so the tree arrives over a separate channel. Recorded
  # the same way so a test can still say what was sent and where.
  defp recording_deliver(owner) do
    fn ref, dir ->
      send(owner, {:delivered, ref, dir})
      :ok
    end
  end

  defp arm, do: {"arm64\n", 0}

  describe "build/4" do
    # Was "fetches only the commit being built", asserting a shallow clone.
    # The builder does not clone at all now: repositories are private and
    # setup installs no deploy key, so cloning could never have worked, and
    # putting a GitHub token on a throwaway box to make it work is the thing
    # this avoids. The commit's tree is sent over the SSH we already have.
    test "the commit being built is delivered, not cloned" do
      run = recorder(self(), %{"inspect" => arm()})

      assert {:ok, _} = Remote.build(%{"ip" => "1.2.3.4"}, "abc123", "reg/app:abc123", opts(run))

      assert_received {:delivered, "abc123", "/build"}

      # Nothing in the sequence reaches GitHub, which is the point.
      refute_received {:ran, "git clone" <> _}
      refute_received {:ran, "git fetch" <> _}
    end

    test "reads the architecture off the image rather than trusting the request" do
      # The point of the whole check: a build that quietly produced x86 must
      # report x86, so Builder can refuse it.
      run = recorder(self(), %{"inspect" => {"amd64\n", 0}})

      assert {:ok, %{architecture: :x86}} =
               Remote.build(%{"ip" => "1.2.3.4"}, "abc123", "reg/app:abc123", opts(run))
    end

    test "a failed build does not push" do
      run =
        recorder(self(), %{
          "docker build" => {"no space left on device", 1},
          "inspect" => arm()
        })

      assert {:error, {:build_failed, 1, output}} =
               Remote.build(%{"ip" => "1.2.3.4"}, "abc123", "reg/app:abc123", opts(run))

      assert output =~ "no space left"

      refute_received {:ran, "docker push" <> _}
    end

    test "a failed push is not reported as a successful build" do
      run =
        recorder(self(), %{
          "docker push" => {"unauthorized", 1},
          "inspect" => arm()
        })

      assert {:error, {:push_failed, 1, "unauthorized"}} =
               Remote.build(%{"ip" => "1.2.3.4"}, "abc123", "reg/app:abc123", opts(run))
    end

    test "gives up on a box that never answers rather than hanging" do
      run = fn _ -> {"connection refused", 255} end

      assert {:error, {:builder_unreachable, _seconds, last}} =
               Remote.build(
                 %{"ip" => "1.2.3.4"},
                 "abc123",
                 "reg/app:abc123",
                 opts(run, ssh_attempts: 3)
               )

      # What SSH last said, because "unreachable" describes a broken box and an
      # impatient caller equally well, and those want opposite responses. A
      # cold Hetzner box takes long enough to reach sshd that the second is the
      # likelier of the two.
      assert last =~ "connection refused"
    end

    test "how long it waited is part of the giving up" do
      run = fn _ -> {"", 255} end

      assert {:error, {:builder_unreachable, seconds, _last}} =
               Remote.build(
                 %{"ip" => "1.2.3.4"},
                 "abc123",
                 "reg/app:abc123",
                 opts(run, ssh_attempts: 3, ssh_interval_ms: 1_000)
               )

      assert seconds == 3
    end

    test "an architecture nobody recognises is an error, not a guess" do
      run = recorder(self(), %{"inspect" => {"riscv64\n", 0}})

      assert {:error, {:unknown_architecture, "riscv64"}} =
               Remote.build(%{"ip" => "1.2.3.4"}, "abc123", "reg/app:abc123", opts(run))
    end
  end

  # A registry reachable on a public hostname must refuse anonymous writes, so
  # a push with no credential is a push that cannot succeed against a registry
  # worth having. This pushed with none at all.
  describe "authenticating to the registry" do
    test "logs in to the reference's host before pushing" do
      run = recorder(self(), %{"inspect" => arm()})

      assert {:ok, _} =
               Remote.build(
                 %{"ip" => "1.2.3.4"},
                 "abc123",
                 "registry.example.com/app:abc123",
                 opts(run, registry_credentials: %{username: "cms", password: "hunter2"})
               )

      [_reachable, _build, _trust, login, push, _inspect] = ran_commands(6)

      assert push =~ "docker push", "the login must come before the push, not after it"

      assert login =~ "docker login 'registry.example.com'"
      assert login =~ "--username 'cms'"

      assert login =~ "--password-stdin",
             "the password must not be an argument — it lands in shell history " <>
               "and in the process list of a box we share"

      refute login =~ "-p hunter2"
    end

    test "the login targets the registry, not the image path" do
      run = recorder(self(), %{"inspect" => arm()})

      assert {:ok, _} =
               Remote.build(
                 %{"ip" => "1.2.3.4"},
                 "abc123",
                 "registry.example.com/some/deep/path:abc123",
                 opts(run, registry_credentials: %{username: "cms", password: "pw"})
               )

      [_reachable, _build, _trust, login, _push, _inspect] = ran_commands(6)

      assert login =~ "docker login 'registry.example.com'"
      refute login =~ "some/deep/path"
    end

    test "a failed login does not push" do
      run =
        recorder(self(), %{
          "docker login" => {"unauthorized", 1},
          "inspect" => arm()
        })

      assert {:error, {:login_failed, 1, "unauthorized"}} =
               Remote.build(
                 %{"ip" => "1.2.3.4"},
                 "abc123",
                 "registry.example.com/app:abc123",
                 opts(run, registry_credentials: %{username: "cms", password: "pw"})
               )

      refute_received {:ran, "docker push" <> _}
    end

    test "no credentials configured stays a no-op" do
      run = recorder(self(), %{"inspect" => arm()})

      assert {:ok, _} =
               Remote.build(%{"ip" => "1.2.3.4"}, "abc123", "reg/app:abc123", opts(run))

      refute_received {:ran, "printf" <> _}
    end
  end

  # The sequence `build/4` runs is fixed — reachability, build, trust, login,
  # push, inspect — so the count is known rather than searched for. Taking a known
  # number and matching positionally says where the login belongs, which "scan
  # forward until something matches" cannot: it would pass just as well if the
  # login came after the push.
  #
  # Source delivery is not in the list: it stopped being a shell command on the
  # builder when the builder stopped cloning.
  defp ran_commands(count) do
    for _ <- 1..count do
      assert_receive {:ran, command}, 0
      command
    end
  end
end
