defmodule CodeMySpecSpex.Fakes.ShellTest do
  @moduledoc """
  The shell fake's effects, which are the whole reason it exists.

  Every assertion here is about what the filesystem looks like *after* a
  command, because that is precisely what a cassette cannot reproduce — it
  replays the stdout and leaves the world untouched, so the next step reads
  something the recording never created.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Environments
  alias CodeMySpec.Support.InMemoryEnvironment
  alias CodeMySpecSpex.Fakes

  setup do
    {:ok, env} = InMemoryEnvironment.create(working_dir: "/memfs")
    previous = Application.get_env(:code_my_spec, :memory_shell)
    Application.put_env(:code_my_spec, :memory_shell, Fakes.Shell)

    on_exit(fn ->
      Application.put_env(:code_my_spec, :memory_shell, previous)
      InMemoryEnvironment.destroy(env)
    end)

    %{env: env}
  end

  # The one that matters. Under a cassette this command replays its output and
  # writes nothing, so a second run mints again and asks for a recording that
  # does not exist.
  test "ssh-keygen leaves a key behind", %{env: env} do
    {_out, 0} =
      Environments.cmd(env, "ssh-keygen", ["-t", "ed25519", "-N", "", "-f", "/memfs/id_ed25519"])

    assert {:ok, private} = Environments.read_file(env, "/memfs/id_ed25519")
    assert private =~ "PRIVATE KEY"

    assert {:ok, public} = Environments.read_file(env, "/memfs/id_ed25519.pub")
    assert public =~ "ssh-ed25519"
  end

  test "the same path twice gives the same key, so a re-run finds what it made", %{env: env} do
    Environments.cmd(env, "ssh-keygen", ["-f", "/memfs/id_ed25519"])
    {:ok, first} = Environments.read_file(env, "/memfs/id_ed25519.pub")

    Environments.cmd(env, "ssh-keygen", ["-f", "/memfs/id_ed25519"])
    {:ok, second} = Environments.read_file(env, "/memfs/id_ed25519.pub")

    assert first == second
  end

  # 963/7965 hit this after the SSH problem was fixed: the server step reads
  # the env file the secrets step writes, and sops cannot operate on a file
  # that is not there.
  test "sops refuses a file that does not exist", %{env: env} do
    assert {output, 128} =
             Environments.cmd(env, "sops", ["encrypt", "--in-place", "envs/prod.enc.env"])

    assert output =~ "non-existent file"
  end

  test "sops succeeds once the file is there", %{env: env} do
    :ok = Environments.write_file(env, "envs/prod.enc.env", "SECRET=1")

    assert {_out, 0} =
             Environments.cmd(env, "sops", ["encrypt", "--in-place", "envs/prod.enc.env"])
  end

  test "age-keygen prints a public key the caller can read back", %{env: env} do
    assert {output, 0} = Environments.cmd(env, "age-keygen", [])
    assert output =~ "public key: age1"
  end

  test "git rev-parse answers a sha", %{env: env} do
    assert {output, 0} = Environments.cmd(env, "git", ["rev-parse", "HEAD"])
    assert String.trim(output) =~ ~r/^[0-9a-f]{16}$/
  end

  # A shell that silently succeeds at everything makes every step pass and
  # proves nothing — worse than the cassettes it replaces.
  test "an unmodelled command fails loudly and names itself", %{env: env} do
    assert {output, 127} = Environments.cmd(env, "kubectl", ["apply", "-f", "-"])
    assert output =~ "kubectl apply"
    assert output =~ "not modelled"
  end
end
