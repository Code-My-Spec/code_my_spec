defmodule CodeMySpec.Release.ReleaseScriptsDecryptTheEnvironmentTest do
  @moduledoc """
  On our own boxes the image carries envs/<env>.enc.env and the container one
  secret, SOPS_AGE_KEY. bin/server and bin/migrate started the release without
  decrypting it, so uat crashed at boot ("GITHUB_CLIENT_ID not set") and its
  migrate died before reaching the database. Fly hands secrets over as plain
  environment and has no key, so there the scripts start as given.

  Run against stand-in `sops` and release binaries that report how they were
  called.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  setup do
    dir = CodeMySpec.TempFile.owned_dir("release-scripts")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    File.mkdir_p!(Path.join(dir, "envs"))

    for script <- ~w(server migrate) do
      File.cp!(Path.join(@root, "rel/overlays/bin/#{script}"), Path.join(bin, script))
      File.chmod!(Path.join(bin, script), 0o755)
    end

    stub(Path.join(bin, "code_my_spec"), ~s(echo "release PHX_SERVER=${PHX_SERVER:-} $*"))
    stub(Path.join(dir, "sops"), ~s(echo "sops $*"))
    %{dir: dir, bin: bin}
  end

  test "with an age key, both scripts run the release through sops exec-env", ctx do
    File.write!(Path.join(ctx.dir, "envs/uat.enc.env"), "ciphertext")
    env = [{"SOPS_AGE_KEY", "AGE-SECRET-KEY-test"}, {"APP_ENV", "uat"}]

    assert run(ctx, "server", env) ==
             "sops exec-env ../envs/uat.enc.env PHX_SERVER=true ./code_my_spec start"

    assert run(ctx, "migrate", env) ==
             "sops exec-env ../envs/uat.enc.env ./code_my_spec eval CodeMySpec.Release.migrate"
  end

  test "with no age key, they start on the environment they were given", ctx do
    assert run(ctx, "server", []) == "release PHX_SERVER=true start"
    assert run(ctx, "migrate", []) == "release PHX_SERVER= eval CodeMySpec.Release.migrate"
  end

  test "a key with no encrypted file for the environment refuses by name", ctx do
    {output, status} = run_raw(ctx, "server", [{"SOPS_AGE_KEY", "k"}, {"APP_ENV", "prod"}])
    assert status != 0
    assert output =~ "has no ../envs/prod.enc.env"
  end

  defp run(ctx, script, env) do
    {output, 0} = run_raw(ctx, script, env)
    String.trim(output)
  end

  defp run_raw(ctx, script, env) do
    System.cmd("/bin/sh", [Path.join(ctx.bin, script)],
      env: [{"PATH", "#{ctx.dir}:/usr/bin:/bin"}, {"PHX_SERVER", nil} | env],
      stderr_to_stdout: true
    )
  end

  defp stub(path, body) do
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
  end
end
