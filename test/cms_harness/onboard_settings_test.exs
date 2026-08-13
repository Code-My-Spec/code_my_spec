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
  use ExUnit.Case, async: true

  alias CodeMySpec.Environments
  alias Mix.Tasks.Cms.Harness.Onboard

  @base "http://localhost:4003"

  setup do
    root = Path.join(System.tmp_dir!(), "onboard-settings-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    # A local environment over the same directory. Onboarding writes through
    # `Environments` so a spec can drive it against the in-memory one; a real
    # directory is still what these assert on, because the file is the point.
    {:ok, env} = Environments.create(:local, working_dir: root)

    {:ok,
     root: root,
     env: env,
     settings_file: Path.join([root, ".claude", "settings.local.json"])}
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

  test "keeps every other setting the operator wrote", %{root: root, env: env, settings_file: file} do
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

  test "re-onboarding to a new id rewrites only the address", %{root: root, env: env, settings_file: file} do
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

  test "treats an empty file as an empty settings object", %{root: root, env: env, settings_file: file} do
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
    test "is a local harness, not the CodeMySpec server", %{root: root, env: env, settings_file: file} do
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
end
