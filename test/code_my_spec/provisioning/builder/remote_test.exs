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
      [run: run, repository_url: "https://github.com/sam/app.git", ssh_interval_ms: 0],
      overrides
    )
  end

  defp arm, do: {"arm64\n", 0}

  describe "build/4" do
    test "fetches only the commit being built" do
      run = recorder(self(), %{"inspect" => arm()})

      assert {:ok, _} = Remote.build(%{"ip" => "1.2.3.4"}, "abc123", "reg/app:abc123", opts(run))

      assert_received {:ran, "true"}
      assert_received {:ran, fetch}

      # Shallow and pinned: the builder does not need the history, and cloning
      # a long-lived repository is the difference between a build that starts
      # now and one that starts in a minute.
      assert fetch =~ "--depth 1"
      assert fetch =~ "abc123"
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

      assert {:error, :builder_unreachable} =
               Remote.build(
                 %{"ip" => "1.2.3.4"},
                 "abc123",
                 "reg/app:abc123",
                 opts(run, ssh_attempts: 3)
               )
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

      assert_receive {:ran, login}, 0, "expected a docker login before the push"
      # Drain to the login command.
      login = drain_until(login, "docker login")

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

      assert_receive {:ran, first}, 0
      login = drain_until(first, "docker login")

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

  # The recorder reports every command, and the login sits between the build
  # and the push; this walks forward to it rather than assuming a position.
  defp drain_until(command, needle) do
    if String.contains?(command, needle) do
      command
    else
      assert_receive {:ran, next}, 0, "never ran a command containing #{inspect(needle)}"
      drain_until(next, needle)
    end
  end
end
