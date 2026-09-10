defmodule CmsHarness.CredentialsTest do
  @moduledoc """
  Which credential a harness presents for which working copy.

  Identity was resolved per working copy and credentials were held per daemon,
  and nothing reconciled the two. A deploy key reaches exactly one project —
  deliberately — while `ProjectIdentity.resolve/1` runs once per root, so a
  daemon serving two projects could only ever join one.

  Measured 2026-08-21: a `broken_oaths` checkout served by the CodeMySpec daemon
  connected its socket (the key is valid) and had every join refused, every
  thirty seconds, with every hook in it answering "channel down, server
  answering 200". It had been invisible only because a separate bug made that
  copy claim the other project's id — which the key does cover — so it joined as
  the wrong project and wrote 8,374 file rows into it.

  The key lives in the copy's own `.cms_harness.json`, beside the identity it
  authenticates and where the harness already walks up to find it. Git never
  sees the file (`.gitignore:103`), and `HarnessConfig.write/2` sets `0600`.

  The order matters in both directions: the copy's own answer has to win over
  the inherited one, and the inherited one has to keep working, because a sprite
  has one project, is handed its key in the environment, and has no file.
  """

  use ExUnit.Case, async: false

  alias CmsHarness.Credentials
  alias CmsHarness.HarnessConfig

  @project "49760b8b-6472-41e2-b05d-c5c97acaee99"

  setup do
    previous_token = Application.get_env(:code_my_spec, :harness_token)
    previous_key = Application.get_env(:code_my_spec, :harness_deploy_key)
    env_token = System.get_env("CMS_TOKEN")
    env_key = System.get_env("CMS_DEPLOY_KEY")

    Application.delete_env(:code_my_spec, :harness_token)
    Application.delete_env(:code_my_spec, :harness_deploy_key)
    System.delete_env("CMS_TOKEN")
    System.delete_env("CMS_DEPLOY_KEY")

    on_exit(fn ->
      restore_app(:harness_token, previous_token)
      restore_app(:harness_deploy_key, previous_key)
      restore_env("CMS_TOKEN", env_token)
      restore_env("CMS_DEPLOY_KEY", env_key)
    end)

    %{root: copy()}
  end

  defp copy do
    root = CodeMySpec.TempFile.dir("working_copy")
    File.mkdir_p!(root)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp onboard(root, opts) do
    :ok =
      HarnessConfig.write(root, %{
        working_copy_id: Keyword.get(opts, :working_copy_id, Ecto.UUID.generate()),
        project_id: Keyword.get(opts, :project_id, @project),
        deploy_key: Keyword.get(opts, :deploy_key),
        root: root
      })
  end

  defp restore_app(key, nil), do: Application.delete_env(:code_my_spec, key)
  defp restore_app(key, value), do: Application.put_env(:code_my_spec, key, value)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  describe "for_working_copy/1" do
    test "a key in the copy's own config beats one inherited from the shell", ctx do
      System.put_env("CMS_DEPLOY_KEY", "the-other-projects-key")
      onboard(ctx.root, deploy_key: "this-copys-key")

      assert {:ok, "this-copys-key", :working_copy_key} =
               Credentials.for_working_copy(ctx.root)
    end

    # The whole failure, in one assertion: two copies, one daemon.
    test "two copies on one daemon each get their own", ctx do
      other = copy()
      onboard(ctx.root, deploy_key: "broken-oaths-key")
      onboard(other, deploy_key: "code-my-spec-key")

      assert {:ok, "broken-oaths-key", :working_copy_key} =
               Credentials.for_working_copy(ctx.root)

      assert {:ok, "code-my-spec-key", :working_copy_key} = Credentials.for_working_copy(other)
    end

    # The environment is not a credential source, and the sprite does not need
    # it to be. `docker/devbox/entrypoint.sh` passes `CMS_DEPLOY_KEY` to
    # `mix harness.onboard`, which writes it into that copy's own
    # `.cms_harness.json` — where `from_working_copy/1` finds it, attributed to
    # the copy it belongs to rather than to whatever launched the daemon.
    test "a copy with no recorded key does not fall back to the environment", ctx do
      System.put_env("CMS_DEPLOY_KEY", "sprite-key")
      onboard(ctx.root, deploy_key: nil)

      assert {:error, :no_credential} = Credentials.for_working_copy(ctx.root),
             "a variable belonging to whichever process started the daemon " <>
               "answered for a copy that never named it"
    end

    test "nor does a directory that was never onboarded at all" do
      System.put_env("CMS_DEPLOY_KEY", "sprite-key")

      assert {:error, :no_credential} =
               Credentials.for_working_copy(CodeMySpec.TempFile.dir("never_onboarded"))
    end

    # A user token reaches every project its user can access, so it answers for
    # all of them and there is nothing to record per copy.
    test "a user token wins over both", ctx do
      Application.put_env(:code_my_spec, :harness_token, "user-token")
      onboard(ctx.root, deploy_key: "this-copys-key")

      assert {:ok, "user-token", :user_token} = Credentials.for_working_copy(ctx.root)
    end

    test "nothing anywhere is no credential, not a blank one", ctx do
      assert {:error, :no_credential} = Credentials.for_working_copy(ctx.root)
    end

    # Application config is now the only thing `Config.user_token/0` and
    # `deploy_key/0` read. It is how the packaged CLI and this suite supply a
    # credential, and it is configuration rather than whatever was exported in
    # one shell.
    test "application config is honoured", ctx do
      Application.put_env(:code_my_spec, :harness_deploy_key, "from-app-config")

      assert {:ok, "from-app-config", :configured_deploy_key} = Credentials.for_working_copy(ctx.root)
    end
  end

  describe "any/0" do
    # `WorkingCopies.ask_server/1` asks where a harness is. The answer does not
    # depend on who asks, and demanding a root would make the lookup impossible
    # for the case it exists to resolve — an id this daemon cannot place on disk.
    test "answers without a working copy" do
      Application.put_env(:code_my_spec, :harness_deploy_key, "configured-key")

      assert {:ok, "configured-key", :configured_deploy_key} = Credentials.any()
    end

    test "and says so when there is nothing to answer with" do
      assert {:error, :no_credential} = Credentials.any()
    end
  end

  describe "the config file" do
    # The hazard the merge exists for: `mint/1` writes the id and the project
    # and knows nothing about the key, so a write that replaced the file would
    # take this copy's credential with it on the next onboard.
    test "a later write that omits the key keeps it", ctx do
      onboard(ctx.root, deploy_key: "recorded", project_id: @project)

      :ok =
        HarnessConfig.write(ctx.root, %{
          working_copy_id: Ecto.UUID.generate(),
          project_id: @project,
          root: ctx.root
        })

      assert {:ok, "recorded", :working_copy_key} = Credentials.for_working_copy(ctx.root)
    end

    test "it is written 0600 — it holds a secret now", ctx do
      onboard(ctx.root, deploy_key: "recorded")

      %File.Stat{mode: mode} = File.stat!(Path.join(ctx.root, ".cms_harness.json"))

      assert Bitwise.band(mode, 0o077) == 0,
             "group and other must have nothing. `.gitignore` keeps this file out of " <>
               "the repository; the mode is what keeps it from other accounts."
    end

    # `read_file/1`, not `read/1`. The second falls through to CMS_HARNESS_ID,
    # which belongs to the daemon rather than to this copy — the same
    # distinction `ProjectIdentity` draws, for the same reason.
    test "an exported harness id does not conjure a credential", ctx do
      previous = System.get_env("CMS_HARNESS_ID")
      System.put_env("CMS_HARNESS_ID", "borrowed-from-another-checkout")
      on_exit(fn -> restore_env("CMS_HARNESS_ID", previous) end)

      assert {:error, :no_credential} = Credentials.for_working_copy(ctx.root)
    end
  end
end
