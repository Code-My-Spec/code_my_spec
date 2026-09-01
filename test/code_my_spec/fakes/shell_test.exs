defmodule CodeMySpecSpex.Fakes.ShellTest do
  @moduledoc """
  The shell fake's effects, which are the whole reason it exists.

  Every assertion here is about what the filesystem looks like *after* a
  command, because that is precisely what a cassette cannot reproduce — it
  replays the stdout and leaves the world untouched, so the next step reads
  something the recording never created.
  """
  # Not async. The shell fake is selected by `:memory_shell` in application
  # env, which is global — every test here setting the same module was
  # survivable, but the injection points below set *different* values
  # (`:memory_shell_push`, `:memory_shell_migration`), and two of those
  # running concurrently would decide each other's outcome. Serialising 72
  # tests that finish in a tenth of a second is the cheap side of that trade.
  use ExUnit.Case, async: false

  alias CodeMySpec.Environments
  alias CodeMySpec.Provisioning.Builder.Remote
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

  # `Remote.ssh_runner/2` wraps its command as `timeout ... sh -c '<command>'`
  # since a hang needs a way to end — this fake has to see through that
  # wrapper the same way a real remote shell parses it back out, or every
  # match below is checking text that no longer appears where it expects to.
  #
  # Built through `Remote.wrap_with_timeout/2` itself rather than a literal
  # string: a hand-written literal is exactly what let `-k 10` slip past this
  # suite once already — the wrapper's own shape changed, the hardcoded test
  # input did not, and the fake silently stopped unwrapping anything at all.
  test "the wrapper around a command does not stop the fake from reading it", %{env: env} do
    wrapped =
      Remote.wrap_with_timeout(
        "docker image inspect --format '{{.Architecture}}' app:abc",
        1800
      )

    assert {output, 0} = Environments.cmd(env, "ssh", ["root@box", wrapped])
    assert String.trim(output) == "amd64"
  end

  # The regression this guards: `backup_args/1` splits on `"bin/backup"` and
  # takes the rest of the string as argv. Left wrapped, the wrapper's own
  # closing quote is the last character of that string — it landed on the
  # environment name, turning `uat` into `uat'` and filing every dump under an
  # environment nothing ever asks about.
  test "a wrapped bin/backup dump still lands under the real environment name", %{env: env} do
    previous = Application.get_env(:code_my_spec, :memory_shell_storage)
    {:ok, agent} = Agent.start_link(&Fakes.Storage.new/0)
    Application.put_env(:code_my_spec, :memory_shell_storage, agent)
    on_exit(fn -> Application.put_env(:code_my_spec, :memory_shell_storage, previous) end)

    command =
      Remote.wrap_with_timeout("cd /opt/app && BACKUP_BUCKET='b' bin/backup dump uat", 1800)

    assert {output, 0} = Environments.cmd(env, "ssh", ["root@box", command])
    assert [_, key] = Regex.run(~r/key=(\S+)/, output)

    assert key =~ ~r{^dumps/uat/}
    assert %{buckets: %{"b" => %{^key => _}}} = Agent.get(agent, & &1)
  end

  test "git rev-parse answers a sha", %{env: env} do
    assert {output, 0} = Environments.cmd(env, "git", ["rev-parse", "HEAD"])
    assert String.trim(output) =~ ~r/^[0-9a-f]{16}$/
  end

  # The three injection points criteria now depend on. Each exists because
  # nothing on this side can know the answer — what a remote holds, what a
  # migration would do — so a fake that guessed would be deciding the criterion
  # rather than serving it. Untested, they are a second implementation nobody
  # checks, which is what this file exists to prevent.

  # 985/8184: a repository that exists but rejects the push is not done.
  test "a push is refused when the spex says the remote has moved on", %{env: env} do
    previous = Application.get_env(:code_my_spec, :memory_shell_push)
    Application.put_env(:code_my_spec, :memory_shell_push, :rejected)
    on_exit(fn -> Application.put_env(:code_my_spec, :memory_shell_push, previous) end)

    assert {output, 1} = Environments.cmd(env, "git", ["push", "-u", "origin", "main"])
    assert output =~ "non-fast-forward"
  end

  test "and lands otherwise", %{env: env} do
    assert {_out, 0} = Environments.cmd(env, "git", ["push", "-u", "origin", "main"])
  end

  # 966/8008: a failed migration leaves the old version serving. The deploy
  # step tells the two apart by exit status, so the status is the fixture.
  test "bin/deploy migrate fails when the spex says the migration does", %{env: env} do
    previous = Application.get_env(:code_my_spec, :memory_shell_migration)
    Application.put_env(:code_my_spec, :memory_shell_migration, :fails)
    on_exit(fn -> Application.put_env(:code_my_spec, :memory_shell_migration, previous) end)

    assert {output, 1} = Environments.cmd(env, "/memfs/bin/deploy", ["migrate", "prod"])
    assert output =~ "Postgrex"

    # Only the migration. A deploy whose migration fails must still be able to
    # report what else it did.
    assert {_out, 0} = Environments.cmd(env, "/memfs/bin/deploy", ["deploy", "prod"])
  end

  # 973's premise: the widget step skips the generator when the file is already
  # there, so writing it is both the effect and what makes a re-run a no-op.
  test "the widget generator leaves the file installed?/2 looks for", %{env: env} do
    :ok = Environments.write_file(env, "lib/app_web/router.ex", "defmodule AppWeb.Router do\nend\n")

    assert {output, 0} = Environments.cmd(env, "mix", ["cms_gen.support_widget"])
    assert output =~ "support_widget_live"

    assert {:ok, contents} =
             Environments.read_file(env, "lib/app_web/live/support_widget_live.ex")

    assert contents =~ "data-cms-widget"
  end

  # A shell that silently succeeds at everything makes every step pass and
  # proves nothing — worse than the cassettes it replaces.
  test "an unmodelled command fails loudly and names itself", %{env: env} do
    assert {output, 127} = Environments.cmd(env, "kubectl", ["apply", "-f", "-"])
    assert output =~ "kubectl apply"
    assert output =~ "not modelled"
  end
end
