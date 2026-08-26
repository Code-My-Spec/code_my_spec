defmodule CmsHarness.OnboardPreviewUrlTest do
  @moduledoc """
  Story 968: the preview's address is set when the main checkout is onboarded,
  and lives in that checkout's own `.cms_harness.json`.

  The file is not empty when this runs. `identity/3` has already recorded
  `working_copy_id` and `project_id` there, and a copy that has been issued one
  carries a `deploy_key` beside them — so the interesting property is not that
  the address lands but that nothing else moves when it does. The first version
  of this wrote a fresh four-key map and took `project_id` with it, which turns
  a working copy into one that can no longer say which project it serves and
  has lost its credential, with nothing in the output naming either.

  `HarnessConfig.write/2` merges for this reason. This path cannot call it —
  the copy may be on another machine and it writes through `Environments` — so
  the merge is reimplemented, and reimplemented behaviour is what a test is
  for.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.HarnessConfig
  alias CodeMySpec.Environments
  alias Mix.Tasks.Cms.Harness.Onboard

  @config ".cms_harness.json"
  @url "https://apricot-tunnel.example.test"

  setup do
    root = CodeMySpec.TempFile.dir("onboard-preview")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, env} = Environments.create(:local, working_dir: root)

    %{root: root, env: env, config_file: Path.join(root, @config)}
  end

  defp existing!(root, map) do
    File.write!(Path.join(root, @config), Jason.encode!(map, pretty: true))
  end

  defp read!(file), do: file |> File.read!() |> Jason.decode!()

  test "records the address in the checkout's own config", ctx do
    existing!(ctx.root, %{"working_copy_id" => "wc-1", "root" => ctx.root})

    assert :ok = Onboard.record_preview_url(ctx.env, ctx.root, "wc-1", @url)

    assert read!(ctx.config_file)["preview_url"] == @url
  end

  test "keeps the project the copy already said it serves", ctx do
    existing!(ctx.root, %{
      "working_copy_id" => "wc-1",
      "harness_id" => "wc-1",
      "project_id" => "proj-9",
      "root" => ctx.root
    })

    assert :ok = Onboard.record_preview_url(ctx.env, ctx.root, "wc-1", @url)

    config = read!(ctx.config_file)

    assert config["project_id"] == "proj-9",
           "recording a preview address dropped `project_id`. That copy now resolves " <>
             "its project from `CMS_PROJECT_ID` — whatever the session that started " <>
             "the daemon happened to carry — and syncs its files into another " <>
             "project's rows with nothing suspicious in any log."

    assert config["preview_url"] == @url
  end

  test "keeps the deploy key, which is the copy's only credential", ctx do
    existing!(ctx.root, %{
      "working_copy_id" => "wc-1",
      "project_id" => "proj-9",
      "deploy_key" => "sk-not-recoverable",
      "root" => ctx.root
    })

    assert :ok = Onboard.record_preview_url(ctx.env, ctx.root, "wc-1", @url)

    assert read!(ctx.config_file)["deploy_key"] == "sk-not-recoverable",
           "the key is decrypted out of the server once and written here; there is no " <>
             "second copy on this machine to restore it from"
  end

  test "writes both id names, so a published binary reading the same file still finds one",
       ctx do
    existing!(ctx.root, %{"working_copy_id" => "wc-1", "root" => ctx.root})

    assert :ok = Onboard.record_preview_url(ctx.env, ctx.root, "wc-1", @url)

    config = read!(ctx.config_file)

    assert config["working_copy_id"] == "wc-1"
    assert config["harness_id"] == "wc-1"
  end

  test "no address given, nothing written", ctx do
    existing!(ctx.root, %{"working_copy_id" => "wc-1", "root" => ctx.root})

    assert :ok = Onboard.record_preview_url(ctx.env, ctx.root, "wc-1", nil)

    refute read!(ctx.config_file)["preview_url"],
           "a checkout with no preview is the ordinary state, and an address invented " <>
             "for it points the panel's frame at nowhere"
  end

  test "a config that cannot be parsed still gets an identity and an address", ctx do
    File.write!(ctx.config_file, "half a json file")

    assert :ok = Onboard.record_preview_url(ctx.env, ctx.root, "wc-1", @url)

    config = read!(ctx.config_file)

    assert config["working_copy_id"] == "wc-1"
    assert config["preview_url"] == @url
  end

  test "what onboarding writes is what the harness reads back", ctx do
    existing!(ctx.root, %{
      "working_copy_id" => "wc-1",
      "project_id" => "proj-9",
      "root" => ctx.root
    })

    assert :ok = Onboard.record_preview_url(ctx.env, ctx.root, "wc-1", @url)

    # The round trip is the point. Onboarding writing a key nothing reads is
    # the same as not writing it, and `HarnessConfig` is the one reader — it is
    # what `ProjectIdentity` resolves through and what the join payload is built
    # from.
    assert {:ok, config} = HarnessConfig.read_file(ctx.root)

    assert config.preview_url == @url
    assert config.project_id == "proj-9"
  end
end
