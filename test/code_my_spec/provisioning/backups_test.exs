defmodule CodeMySpec.Provisioning.BackupsTest do
  @moduledoc """
  Covers the environment the backup script is handed, against real `sops`.

  ## Why this test exists at all

  Story 968's spex replay the dump through a cassette, and a cassette matches
  on the command and its arguments — not on the environment the process was
  given. So the suite was green while `bin/backup` was being started with no
  way to read its own credentials: the script's first act is
  `source <(sops -d "$file")`, sops takes its identity from `SOPS_AGE_KEY` and
  nowhere else, and nothing set it.

  That is a defect a cassette structurally cannot see, which is why this is a
  test and not another criterion.

  ## Why real sops

  The claim is "the script can decrypt its own env file". A stub would assert
  that we passed a variable named `SOPS_AGE_KEY`, which is what the broken
  version would also have looked like from the outside if we had written the
  assertion first. Only the real binary can answer whether the value we pass
  is one sops accepts as an identity.

  Skipped when the binaries are absent, so a machine without them reports a
  skip rather than a failure that reads like a code defect.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Provisioning.{Backups, Sops}

  @moduletag :sops

  @database_url "ecto://backups_test@localhost/prod"

  setup do
    if Sops.available?() do
      {:ok, tmp} = Briefly.create(directory: true)
      env = Environment.new(:local, tmp)

      {:ok, {pub, priv}} = Sops.generate_key()
      :ok = Sops.write_config(env, %{"prod" => pub})
      :ok = Sops.put_secret(env, "prod", "DATABASE_URL", @database_url, priv)

      write_backup_script(tmp)

      {:ok, env: env, tmp: tmp, key: priv}
    else
      {:ok, skip: true}
    end
  end

  describe "the environment handed to bin/backup" do
    test "carries the age key, so the script decrypts its own DATABASE_URL", ctx do
      if ctx[:skip], do: :ok, else: assert_decrypts(ctx)
    end

    test "without the key, the script cannot read its credentials", ctx do
      if ctx[:skip], do: :ok, else: assert_fails_without_key(ctx)
    end

    test "the file's value wins over a passed database_url, so the key is the fix", ctx do
      if ctx[:skip], do: :ok, else: assert_file_wins(ctx)
    end

    # Found live against broken_oaths: `put_database_url/3` (steps.ex) has
    # always handed the connection string over directly rather than
    # leaving it to be decrypted, and `restore_admin_url` was added
    # without a matching `restore_admin_url:` slot in `script_env/1` — the
    # encrypted file had the right value, the step just never passed it
    # through, the same class of gap `assert_file_wins` already guards for
    # `database_url`.
    test "restore_admin_url reaches the script as CMS_RESTORE_ADMIN_URL", ctx do
      if ctx[:skip], do: :ok, else: assert_restore_admin_url_passed(ctx)
    end
  end

  defp assert_decrypts(ctx) do
    assert {:ok, key, _source_rows} =
             Backups.take_dump(ctx.env, "prod",
               credentials: credentials(),
               bucket: "b",
               age_key: ctx.key
             )

    # The fake script reports the URL it managed to source, so the key it
    # returns is proof the decryption happened rather than proof it ran.
    assert key == "prod/#{@database_url}"
  end

  defp assert_fails_without_key(ctx) do
    # The regression itself: same call, no key. sops has no identity, the
    # script's `source` yields nothing, and the dump has no credentials.
    assert {:error, message} =
             Backups.take_dump(ctx.env, "prod", credentials: credentials(), bucket: "b")

    assert message =~ "no DATABASE_URL"
  end

  # Records why the key, and not the connection string, was the right thing to
  # pass. The script sources its env file unconditionally, so a `DATABASE_URL`
  # handed in through the environment is overwritten by the file's own value
  # the moment the decryption succeeds. The `database_url` slot in
  # `script_env/1` therefore only reaches a box that has no encrypted file —
  # which is not the box backups run on.
  defp assert_file_wins(ctx) do
    assert {:ok, key, _source_rows} =
             Backups.take_dump(ctx.env, "prod",
               credentials: credentials(),
               bucket: "b",
               age_key: ctx.key,
               database_url: "ecto://passed-in"
             )

    assert key == "prod/#{@database_url}"
  end

  defp assert_restore_admin_url_passed(ctx) do
    assert {:error, message} =
             Backups.restore_proof(ctx.env, "some-key", age_key: ctx.key, expected_rows: 3)

    assert message =~ "no CMS_RESTORE_ADMIN_URL",
           "restore_admin_url never reached the script as CMS_RESTORE_ADMIN_URL: #{message}"

    assert {:ok, %{rows: 3}} =
             Backups.restore_proof(ctx.env, "some-key",
               age_key: ctx.key,
               expected_rows: 3,
               restore_admin_url: "ecto://restore@localhost/postgres"
             )
  end

  defp credentials, do: [access_key_id: "id", secret_access_key: "secret", region: "nbg1"]

  # Stands in for the generated script, decrypting with the same binary and the
  # same file — a fake that got its value some other way would prove nothing
  # about the real one.
  #
  # It differs from `DeployArtifacts` in one construct: the generated script
  # writes `source <(sops -d "$file")`, and macOS ships bash 3.2, where process
  # substitution silently yields an empty stream. `eval "$(...)"` is the same
  # decryption through a construct 3.2 has, so this asserts the property the
  # defect was about — the key arrives and sops accepts it — on any machine.
  defp write_backup_script(tmp) do
    path = Path.join(tmp, "bin/backup")
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    #!/usr/bin/env bash
    set -uo pipefail
    file="envs/prod.enc.env"
    if command -v sops >/dev/null 2>&1; then eval "$(sops -d "$file")"; else source "$file"; fi
    if [ -z "${DATABASE_URL:-}" ]; then echo "no DATABASE_URL"; exit 1; fi
    if [ "$1" = "restore" ]; then
      if [ -z "${CMS_RESTORE_ADMIN_URL:-}" ]; then echo "no CMS_RESTORE_ADMIN_URL"; exit 1; fi
      echo "rows=3"
      exit 0
    fi
    echo "key=$2/$DATABASE_URL"
    """)

    File.chmod!(path, 0o755)
  end
end
