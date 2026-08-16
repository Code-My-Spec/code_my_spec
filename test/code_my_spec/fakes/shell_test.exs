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

  # The one the deploy step turns on. `missing_secrets/4` decrypts and reads
  # the keys back, so a sops that exits 0 while printing nothing answers
  # "everything is missing" — which is how a fully provisioned run reported
  # "prod is missing SECRET_KEY_BASE, DATABASE_URL" one step from the end.
  test "a secret set is a secret read back", %{env: env} do
    :ok = Environments.write_file(env, "envs/prod.enc.env", "SOPS_INITIALIZED=true\n")

    {_out, 0} =
      Environments.cmd(env, "sops", ["set", "envs/prod.enc.env", ~s(["SECRET_KEY_BASE"]), ~s("abc")])

    assert {output, 0} = Environments.cmd(env, "sops", ["decrypt", "envs/prod.enc.env"])
    assert output =~ "SECRET_KEY_BASE=abc"
  end

  test "setting a key twice leaves one of it", %{env: env} do
    :ok = Environments.write_file(env, "envs/prod.enc.env", "")

    for value <- ~w(first second) do
      {_out, 0} =
        Environments.cmd(env, "sops", ["set", "envs/prod.enc.env", ~s(["K"]), ~s("#{value}")])
    end

    assert {output, 0} = Environments.cmd(env, "sops", ["decrypt", "envs/prod.enc.env"])
    assert output =~ "K=second"
    refute output =~ "K=first"
  end

  # `Sops.ensure_encrypted/2` detects this state by matching sops' own message
  # text, so the wording is load-bearing: a refusal phrased differently reads
  # as a genuine failure and the secrets step reports `{:sops_failed, 1, …}`
  # over a file that is perfectly fine.
  test "encrypting twice refuses in sops' own words", %{env: env} do
    :ok = Environments.write_file(env, "envs/prod.enc.env", "K=1\n")
    {_out, 0} = Environments.cmd(env, "sops", ["encrypt", "--in-place", "envs/prod.enc.env"])

    assert {output, 1} =
             Environments.cmd(env, "sops", ["encrypt", "--in-place", "envs/prod.enc.env"])

    assert output =~ "already being encrypted"
  end

  # `require_script/2` asks whether the script is executable, not whether it is
  # there — and the memory environment used to answer that from the real disk,
  # so every generated script read as missing.
  test "a script is executable only after chmod", %{env: env} do
    :ok = Environments.write_file(env, "bin/deploy", "#!/bin/sh\n")
    refute Environments.exec_file_exists?(env, "bin/deploy")

    {_out, 0} = Environments.cmd(env, "chmod", ["+x", "bin/deploy"])
    assert Environments.exec_file_exists?(env, "bin/deploy")
  end

  test "the box answers what architecture its image is", %{env: env} do
    assert {output, 0} =
             Environments.cmd(env, "ssh", [
               "root@box",
               "docker image inspect --format '{{.Architecture}}' app:abc"
             ])

    # Not "": that arrives as `{:unknown_architecture, ""}`, which reads as a
    # box answering something strange rather than one not answering.
    assert String.trim(output) == "amd64"
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
