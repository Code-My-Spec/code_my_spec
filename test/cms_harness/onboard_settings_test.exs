defmodule CmsHarness.OnboardSettingsTest do
  @moduledoc """
  Onboarding writes `ANTHROPIC_BASE_URL` into a working copy's
  `.claude/settings.local.json`, because a Claude Code plugin cannot set an
  environment variable for the session and the agent process is what reads that
  one. Without it a model turn arrives unaddressed, and an unaddressed turn is
  only attributable when the harness serves exactly one working copy — a
  sprite's shape, never a developer's.

  It goes in `settings.local.json` rather than the tracked `settings.json`,
  because the URL carries this working copy's harness id and committing that
  would hand one machine's identity to every checkout. The operator may still
  have written in it, so the thing worth pinning is not that the URL lands but
  that nothing else moves when it does.
  """
  # Sync: this mutates OS environment variables, which belong to the BEAM node
  # rather than to a test process. Saving and restoring them is careful and
  # still leaves a window every concurrent test can see.
  use ExUnit.Case, async: false

  alias CodeMySpec.Environments
  alias Mix.Tasks.Cms.Harness.Onboard

  @base "http://localhost:4003"

  setup do
    root = CodeMySpec.TempFile.dir("onboard-settings")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    # A local environment over the same directory. Onboarding writes through
    # `Environments` so a spec can drive it against the in-memory one; a real
    # directory is still what these assert on, because the file is the point.
    {:ok, env} = Environments.create(:local, working_dir: root)

    {:ok,
     root: root, env: env, settings_file: Path.join([root, ".claude", "settings.local.json"])}
  end

  defp read!(file), do: file |> File.read!() |> Jason.decode!()

  test "writes the addressed URL when there is no settings file", %{
    root: root,
    env: env,
    settings_file: file
  } do
    assert :ok = Onboard.address_model_turns(env, root, "abc-123", @base)

    assert read!(file)["env"]["ANTHROPIC_BASE_URL"] ==
             "#{@base}/api/harnesses/abc-123"
  end

  test "writes the harness id, which is the only way MCP can name this checkout", %{
    root: root,
    env: env,
    settings_file: file
  } do
    assert :ok = Onboard.address_model_turns(env, root, "abc-123", @base)

    assert read!(file)["env"]["CMS_HARNESS_ID"] == "abc-123",
           "the plugin's MCP mount sends `X-Harness-Id: ${CMS_HARNESS_ID}` because an " <>
             "mcpServers entry interpolates environment variables and cannot read " <>
             ".cms_harness.json the way the hook shims do. Unset, it arrives as that " <>
             "literal string — which the server refuses now that identity is the only " <>
             "routing key."
  end

  test "keeps every other setting the operator wrote", %{
    root: root,
    env: env,
    settings_file: file
  } do
    File.mkdir_p!(Path.dirname(file))

    File.write!(
      file,
      Jason.encode!(%{
        "permissions" => %{"allow" => ["Bash(git status)"]},
        "env" => %{"FOO" => "bar"}
      })
    )

    assert :ok = Onboard.address_model_turns(env, root, "abc-123", @base)

    settings = read!(file)

    assert settings["permissions"] == %{"allow" => ["Bash(git status)"]},
           "onboarding replaced settings it does not own"

    assert settings["env"]["FOO"] == "bar",
           "onboarding dropped an env var it does not own"

    assert settings["env"]["ANTHROPIC_BASE_URL"] == "#{@base}/api/harnesses/abc-123"
  end

  test "re-onboarding to a new id rewrites only the address", %{
    root: root,
    env: env,
    settings_file: file
  } do
    assert :ok = Onboard.address_model_turns(env, root, "first", @base)
    assert :ok = Onboard.address_model_turns(env, root, "second", @base)

    env = read!(file)["env"]

    assert env["ANTHROPIC_BASE_URL"] == "#{@base}/api/harnesses/second"
    refute env["ANTHROPIC_BASE_URL"] =~ "first"
  end

  test "refuses a malformed settings file rather than overwriting it", %{
    root: root,
    env: env,
    settings_file: file
  } do
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "{ this is not json")

    assert {:error, message} = Onboard.address_model_turns(env, root, "abc-123", @base)
    assert message =~ "settings.local.json"

    assert File.read!(file) == "{ this is not json",
           "a file we could not parse is a file we must not replace"
  end

  test "treats an empty file as an empty settings object", %{
    root: root,
    env: env,
    settings_file: file
  } do
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "")

    assert :ok = Onboard.address_model_turns(env, root, "abc-123", @base)
    assert read!(file)["env"]["ANTHROPIC_BASE_URL"] == "#{@base}/api/harnesses/abc-123"
  end

  # Every test above injects `@base`, which is the whole reason the default went
  # unnoticed: it used to be `Config.server_url()` — the CodeMySpec server —
  # and `/api/harnesses/:id/v1/messages` exists only in `CmsHarness.Web.Router`.
  # An agent pointed at the cloud posts every turn to a route that is not there,
  # so the feature could not have worked as shipped.
  #
  # The parameter that exists "only so it can be tested directly" was exactly
  # what kept the real path untested. So these exercise the default.
  describe "the address it picks when nobody passes one" do
    test "is a local harness, not the CodeMySpec server", %{
      root: root,
      env: env,
      settings_file: file
    } do
      assert :ok = Onboard.address_model_turns(env, root, "abc-123")

      url = read!(file)["env"]["ANTHROPIC_BASE_URL"]

      assert url =~ ~r{^http://localhost:\d+/api/harnesses/abc-123$},
             "got #{url} — the proxy route only exists on the harness"

      refute url =~ "codemyspec.com",
             "the cloud has no /v1/messages; pointing an agent there breaks every turn"
    end

    test "follows CMS_HARNESS_PORT, which is what a sprite sets", %{
      root: root,
      env: env,
      settings_file: file
    } do
      System.put_env("CMS_HARNESS_PORT", "4321")
      on_exit(fn -> System.delete_env("CMS_HARNESS_PORT") end)

      assert :ok = Onboard.address_model_turns(env, root, "abc-123")

      assert read!(file)["env"]["ANTHROPIC_BASE_URL"] ==
               "http://localhost:4321/api/harnesses/abc-123"
    end
  end

  describe "the databases a report names" do
    # `Mix.Project.config()[:app]` answers for the project the VM booted, which
    # is this repo — so onboarding another directory named its databases after
    # this one. Measured 2026-08-20: a generated application called `verifyapp`
    # was told it needed `code_my_spec_testhf3e24487`, while running
    # `mix harness.onboard` inside it correctly said `verifyapp_testhf3e24487`.
    # The partition agreed in both, since it is derived from the path; only the
    # prefix was wrong, and wrong in the direction of naming a database that
    # belongs to a different application.
    #
    # `client_utils` warned about this exact symptom in `onboard_opts/1` — "a
    # printed command that creates a different database than the one it names"
    # — after it was caused by defaulting the value. It stopped being defaulted
    # and started being read from the wrong project.
    test "are named after the app being onboarded, not the one running the task" do
      root = CodeMySpec.TempFile.dir("onboard-app-name")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)

      File.write!(root <> "/mix.exs", """
      defmodule Verifyapp.MixProject do
        use Mix.Project

        def project do
          [
            app: :verifyapp,
            version: "0.1.0"
          ]
        end
      end
      """)

      assert Onboard.target_app(root) == :verifyapp,
             "the report names databases for the target, so it has to read the " <>
               "target's own mix.exs rather than the project this task booted in"
    end

    # Onboarding this checkout is the common case and must not start parsing a
    # file to answer a question the VM already knows.
    test "the running project answers for itself" do
      assert Onboard.target_app(File.cwd!()) == Mix.Project.config()[:app]
    end

    # A compromise, recorded so it is not mistaken for an oversight: this is the
    # old behaviour, and it is wrong in the same way. It is chosen over refusing
    # because the names are informational now — nothing runs the printed
    # commands, since the first `mix test` creates what it needs — so a wrong
    # prefix misinforms where a refusal would block an onboarding with nothing
    # else wrong with it.
    test "a target with no readable mix.exs keeps the running project's answer" do
      root = CodeMySpec.TempFile.dir("onboard-app-name-missing")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)

      assert Onboard.target_app(root) == Mix.Project.config()[:app]
    end
  end
end
