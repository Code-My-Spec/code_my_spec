defmodule CmsHarness.OnboardSettingsTest do
  @moduledoc """
  Onboarding writes `ANTHROPIC_BASE_URL` into a working copy's
  `.claude/settings.json`, because a Claude Code plugin cannot set an
  environment variable for the session and the agent process is what reads that
  one. Without it a model turn arrives unaddressed, and an unaddressed turn is
  only attributable when the harness serves exactly one working copy — a
  sprite's shape, never a developer's.

  Unlike the generated plugin copy, this file belongs to the operator and is
  checked in. So the thing worth pinning is not that the URL lands but that
  nothing else moves when it does.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Cms.Harness.Onboard

  @base "http://localhost:4003"

  setup do
    root = Path.join(System.tmp_dir!(), "onboard-settings-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root, settings_file: Path.join([root, ".claude", "settings.json"])}
  end

  defp read!(file), do: file |> File.read!() |> Jason.decode!()

  test "writes the addressed URL when there is no settings file", %{
    root: root,
    settings_file: file
  } do
    assert :ok = Onboard.address_model_turns(root, "abc-123", @base)

    assert read!(file)["env"]["ANTHROPIC_BASE_URL"] ==
             "#{@base}/api/harnesses/abc-123"
  end

  test "keeps every other setting the operator wrote", %{root: root, settings_file: file} do
    File.mkdir_p!(Path.dirname(file))

    File.write!(
      file,
      Jason.encode!(%{
        "permissions" => %{"allow" => ["Bash(git status)"]},
        "env" => %{"FOO" => "bar"}
      })
    )

    assert :ok = Onboard.address_model_turns(root, "abc-123", @base)

    settings = read!(file)

    assert settings["permissions"] == %{"allow" => ["Bash(git status)"]},
           "onboarding replaced settings it does not own"

    assert settings["env"]["FOO"] == "bar",
           "onboarding dropped an env var it does not own"

    assert settings["env"]["ANTHROPIC_BASE_URL"] == "#{@base}/api/harnesses/abc-123"
  end

  test "re-onboarding to a new id rewrites only the address", %{root: root, settings_file: file} do
    assert :ok = Onboard.address_model_turns(root, "first", @base)
    assert :ok = Onboard.address_model_turns(root, "second", @base)

    env = read!(file)["env"]

    assert env["ANTHROPIC_BASE_URL"] == "#{@base}/api/harnesses/second"
    refute env["ANTHROPIC_BASE_URL"] =~ "first"
  end

  test "refuses a malformed settings file rather than overwriting it", %{
    root: root,
    settings_file: file
  } do
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "{ this is not json")

    assert {:error, message} = Onboard.address_model_turns(root, "abc-123", @base)
    assert message =~ "settings.json"

    assert File.read!(file) == "{ this is not json",
           "a file we could not parse is a file we must not replace"
  end

  test "treats an empty file as an empty settings object", %{root: root, settings_file: file} do
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "")

    assert :ok = Onboard.address_model_turns(root, "abc-123", @base)
    assert read!(file)["env"]["ANTHROPIC_BASE_URL"] == "#{@base}/api/harnesses/abc-123"
  end
end
