defmodule CodeMySpec.Files.FileSyncTest do
  use ExUnit.Case, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Projects
  alias CodeMySpec.WorkingCopies
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "classify/1" do
    test "classifies implementation files" do
      assert {:implementation, _} = swap(FileSync.classify("lib/my_app/accounts.ex"))
    end

    test "classifies test files" do
      assert {:test, _} = swap(FileSync.classify("test/my_app/accounts_test.exs"))
    end

    test "does not track component spec files" do
      assert nil == FileSync.classify(".code_my_spec/spec/my_app/accounts.spec.md")
    end

    test "classifies bdd spec files" do
      assert {:bdd_spec, _} = swap(FileSync.classify("test/spex/my_app/accounts_spex.exs"))
    end

    test "classifies rule files" do
      assert {:rule, _} = swap(FileSync.classify(".code_my_spec/rules/context.md"))
    end

    test "classifies qa brief files" do
      assert {:qa_brief, _} = swap(FileSync.classify(".code_my_spec/qa/440/brief.md"))
    end

    test "classifies only result_complete.md as qa_result; in-progress and failed runs are not role-tagged" do
      assert {:qa_result, _} = swap(FileSync.classify(".code_my_spec/qa/440/result_complete.md"))
      assert is_nil(FileSync.classify(".code_my_spec/qa/440/result.md"))
      assert is_nil(FileSync.classify(".code_my_spec/qa/440/result_failed_20260318_041104.md"))
    end

    test "does not classify qa screenshots" do
      assert is_nil(FileSync.classify(".code_my_spec/qa/440/screenshots/01_page.png"))
    end

    test "classifies CLAUDE.md as claude_md" do
      assert {:claude_md, _} = swap(FileSync.classify("CLAUDE.md"))
    end

    test "classifies config.yml as setup_config" do
      assert {:setup_config, _} = swap(FileSync.classify(".code_my_spec/config.yml"))
    end

    test "classifies mix.exs as mix_exs" do
      assert {:mix_exs, _} = swap(FileSync.classify("mix.exs"))
    end

    test "classifies .credo.exs as credo_exs" do
      assert {:credo_exs, _} = swap(FileSync.classify(".credo.exs"))
    end

    test "classifies .code_my_spec/AGENTS.md as agents_md" do
      assert {:agents_md, _} = swap(FileSync.classify(".code_my_spec/AGENTS.md"))
    end

    test "classifies test/support/<app>_spex.ex as test_support" do
      assert {:test_support, _} = swap(FileSync.classify("test/support/my_app_spex.ex"))
    end

    test "classifies test/support/conn_case.ex as test_support" do
      assert {:test_support, _} = swap(FileSync.classify("test/support/conn_case.ex"))
    end

    test "returns nil for unrecognized files" do
      assert is_nil(FileSync.classify("README.md"))
      assert is_nil(FileSync.classify("assets/js/app.js"))
    end

    # Found live against MarketMySpec: the sync's own scan was genuinely
    # healthy (a real scan, a real reconcile, real rows landing) and every
    # deploy artifact still reported missing, because `bin`/`.github`/
    # `config`/`rel`/`envs` and the plaintext root files were outside
    # `@sync_roots` entirely — walking them alone would not have been
    # enough either, since classify/1 returning nil is what drops a path
    # before it ever becomes a row.
    test "classifies deploy boilerplate as deploy_artifact" do
      for path <- [
            "Dockerfile",
            ".sops.yaml",
            ".env",
            ".env.local",
            ".env.production",
            ".env.schema",
            "bin/deploy",
            "bin/backup",
            ".github/workflows/build.yml",
            "config/deploy.yml",
            "config/deploy.uat.yml",
            "rel/overlays/bin/boot",
            "rel/overlays/bin/migrate"
          ] do
        assert {:deploy_artifact, ^path} = swap(FileSync.classify(path)),
               "expected #{path} to classify as deploy_artifact"
      end
    end

    # Split out of :deploy_artifact — the one deploy artifact a check needs
    # content from, not just existence. See `check_secrets/2`'s missing_
    # required_secrets/2` and `Scanner.validate_entry/4`'s `:encrypted_env`
    # clause.
    test "classifies an environment's encrypted file as encrypted_env" do
      for path <- ["envs/prod.enc.env", "envs/uat.enc.env"] do
        assert {:encrypted_env, ^path} = swap(FileSync.classify(path)),
               "expected #{path} to classify as encrypted_env"
      end
    end

    test "returns nil for files in ignored dirs" do
      # These would be filtered by ignored_path? before classify,
      # but classify itself doesn't match them either
      assert is_nil(FileSync.classify("deps/phoenix/lib/phoenix.ex"))
    end

    # Swap {path, role} to {role, path} for pattern matching on role
    defp swap({path, role}), do: {role, path}
    defp swap(nil), do: nil
  end

  describe "sync/2" do
    test "scans filesystem and creates File records" do
      {scope, tmp_dir} = setup_project()

      # Seed some files
      write_file(tmp_dir, "lib/my_app/accounts.ex", "defmodule MyApp.Accounts do\nend")

      write_file(tmp_dir, ".code_my_spec/rules/context.md", "# Context rules")
      write_file(tmp_dir, "CLAUDE.md", "# Project")

      {:ok, result} = FileSync.sync(scope, base_dir: tmp_dir)

      assert result.total_files >= 3
      assert result.upserted >= 3

      files = Files.list_files(scope)
      paths = Enum.map(files, & &1.path)

      assert "lib/my_app/accounts.ex" in paths
      assert ".code_my_spec/rules/context.md" in paths
      assert "CLAUDE.md" in paths
    end

    # The real incident, end to end: a harness-scoped devops call can't see
    # a live checkout, so `DeployBoilerplate.present?/2` falls back to this
    # table — and a real scan of MarketMySpec's actual checkout produced
    # rows for every real file except its deploy boilerplate, because
    # `bin`/`.github`/`config`/`rel`/`envs` were never walked at all.
    test "a real scan picks up deploy boilerplate outside lib/test" do
      {scope, tmp_dir} = setup_project()

      write_file(tmp_dir, "Dockerfile", "FROM elixir:1.19\n")
      write_file(tmp_dir, ".sops.yaml", "creation_rules: []\n")
      write_file(tmp_dir, "bin/deploy", "#!/bin/sh\nkamal deploy\n")
      write_file(tmp_dir, ".github/workflows/build.yml", "name: build\n")
      write_file(tmp_dir, "config/deploy.yml", "service: app\n")
      write_file(tmp_dir, "rel/overlays/bin/boot", "#!/bin/sh\n")
      write_file(tmp_dir, "envs/prod.enc.env", "SECRET_KEY_BASE=ENC[...]\n")

      {:ok, _result} = FileSync.sync(scope, base_dir: tmp_dir)

      paths = scope |> Files.list_files() |> Enum.map(& &1.path)

      for path <- [
            "Dockerfile",
            ".sops.yaml",
            "bin/deploy",
            ".github/workflows/build.yml",
            "config/deploy.yml",
            "rel/overlays/bin/boot",
            "envs/prod.enc.env"
          ] do
        assert path in paths, "expected #{path} to be synced, got #{inspect(paths)}"
      end
    end

    # `check_secrets/2` reads this verdict rather than the file, so the
    # server never needs `Environments.read_file/2` to reach a harness-only
    # project — and no decryption happens here either: SOPS's dotenv mode
    # encrypts values only, so key names are plaintext exactly as committed.
    test "an encrypted env file with both required secrets is valid" do
      {scope, tmp_dir} = setup_project()

      write_file(tmp_dir, "envs/prod.enc.env", """
      SECRET_KEY_BASE=ENC[AES256_GCM,data:aaaa,iv:bbbb,tag:cccc,type:str]
      DATABASE_URL=ENC[AES256_GCM,data:dddd,iv:eeee,tag:ffff,type:str]
      """)

      {:ok, _result} = FileSync.sync(scope, base_dir: tmp_dir)

      file = Files.get_by_path(scope, "envs/prod.enc.env")

      assert file.valid == true
      assert file.validation_errors["data"]["missing"] == []

      assert Enum.sort(file.validation_errors["data"]["present"]) ==
               ["DATABASE_URL", "SECRET_KEY_BASE"]
    end

    test "an encrypted env file missing a required secret is invalid, by name" do
      {scope, tmp_dir} = setup_project()

      write_file(tmp_dir, "envs/prod.enc.env", """
      SECRET_KEY_BASE=ENC[AES256_GCM,data:aaaa,iv:bbbb,tag:cccc,type:str]
      """)

      {:ok, _result} = FileSync.sync(scope, base_dir: tmp_dir)

      file = Files.get_by_path(scope, "envs/prod.enc.env")

      assert file.valid == false
      assert file.validation_errors["data"]["missing"] == ["DATABASE_URL"]
      assert file.validation_errors["data"]["present"] == ["SECRET_KEY_BASE"]
    end

    test "full sync reports only fingerprint-changed paths" do
      {scope, tmp_dir} = setup_project()

      write_file(tmp_dir, "lib/my_app/accounts.ex", "defmodule MyApp.Accounts do\nend")

      # First sync sees the file as new — must report it as changed.
      {:ok, result1} = FileSync.sync(scope, base_dir: tmp_dir)
      assert "lib/my_app/accounts.ex" in result1.changed_paths

      # Second sync with no on-disk edits reports an empty diff —
      # otherwise downstream consumers (embedding, the /files panel)
      # would do redundant work on every sync. Story 688: "Files whose
      # checksum is unchanged are skipped."
      {:ok, result2} = FileSync.sync(scope, base_dir: tmp_dir)
      refute "lib/my_app/accounts.ex" in result2.changed_paths
      assert result2.changed_paths == []

      # Editing the file's content puts it back in the diff.
      write_file(tmp_dir, "lib/my_app/accounts.ex", "defmodule MyApp.Accounts do\n  # v2\nend")

      {:ok, result3} = FileSync.sync(scope, base_dir: tmp_dir)
      assert "lib/my_app/accounts.ex" in result3.changed_paths
    end

    test "removes files that no longer exist on disk" do
      {scope, tmp_dir} = setup_project()

      path = write_file(tmp_dir, "lib/my_app/old.ex", "defmodule MyApp.Old do\nend")

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)
      assert Files.get_by_path(scope, "lib/my_app/old.ex")

      File.rm!(path)

      {:ok, result} = FileSync.sync(scope, base_dir: tmp_dir)
      assert result.removed >= 1
      refute Files.get_by_path(scope, "lib/my_app/old.ex")
    end

    test "assigns component_id to implementation files" do
      {scope, tmp_dir} = setup_project()

      {:ok, component} =
        CodeMySpec.Components.create_component(scope, %{
          name: "Accounts",
          type: "schema",
          module_name: "MyApp.Accounts"
        })

      write_file(tmp_dir, "lib/my_app/accounts.ex", "defmodule MyApp.Accounts do\nend")

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      impl_file = Files.get_by_path(scope, "lib/my_app/accounts.ex")
      assert impl_file.component_id == component.id
      assert impl_file.role == :implementation
    end

    test "a spec file is not tracked at all" do
      {scope, tmp_dir} = setup_project()

      # Components are records (3aeb66cf); a spec describes nothing and is not
      # a project file anything reads.
      write_file(tmp_dir, ".code_my_spec/spec/my_app/broken.spec.md", "# MyApp.Broken\n")

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      refute Files.get_by_path(scope, ".code_my_spec/spec/my_app/broken.spec.md")
    end

    test "does not compare unit tests with markdown assertions" do
      {scope, tmp_dir} = setup_project()

      spec_content = """
      # MyApp.UserLive.Show

      Shows a user.

      ## Type

      liveview

      ## Route

      `/users/:id`

      ## User Interactions

      - **phx-click=edit**: Opens edit form

      ## Dependencies

      - MyApp.Users

      ## Design

      Layout: Detail view.

      ## Test Assertions

      - renders user details
      - opens edit form on click
      - handles missing user
      """

      # Test only covers one of three assertions
      partial_test = """
      defmodule MyApp.UserLive.ShowTest do
        use ExUnit.Case

        describe "renders user details" do
          test "shows user" do
            assert true
          end
        end
      end
      """

      {:ok, _component} =
        CodeMySpec.Components.create_component(scope, %{
          name: "Show",
          type: "liveview",
          module_name: "MyApp.UserLive.Show"
        })

      write_file(tmp_dir, ".code_my_spec/spec/my_app/user_live/show.spec.md", spec_content)
      write_file(tmp_dir, "test/my_app/user_live/show_test.exs", partial_test)

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      test_file = Files.get_by_path(scope, "test/my_app/user_live/show_test.exs")
      assert test_file.valid == true
      assert test_file.validation_errors == nil
    end

    test "ignores deps, _build, .git directories" do
      {scope, tmp_dir} = setup_project()

      write_file(tmp_dir, "deps/phoenix/lib/phoenix.ex", "defmodule Phoenix do\nend")
      write_file(tmp_dir, "_build/dev/lib/my_app.ex", "defmodule MyApp do\nend")
      write_file(tmp_dir, "lib/my_app/real.ex", "defmodule MyApp.Real do\nend")

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      files = Files.list_files(scope)
      paths = Enum.map(files, & &1.path)

      assert "lib/my_app/real.ex" in paths
      refute Enum.any?(paths, &String.starts_with?(&1, "deps/"))
      refute Enum.any?(paths, &String.starts_with?(&1, "_build/"))
    end
  end

  describe "sync_changed/2" do
    test "skips unchanged files and only upserts new or modified ones" do
      {scope, tmp_dir} = setup_project()

      write_file(tmp_dir, "lib/my_app/accounts.ex", "defmodule MyApp.Accounts do\nend")
      write_file(tmp_dir, "lib/my_app/users.ex", "defmodule MyApp.Users do\nend")

      # Full sync to populate DB
      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      # Second sync with no changes — nothing should be upserted
      {:ok, result} = FileSync.sync_changed(scope, base_dir: tmp_dir)
      assert result.upserted == 0
      assert result.changed_paths == []
      assert result.total_files >= 2

      # Bump mtime explicitly instead of sleeping past the 1s POSIX granularity
      write_file(
        tmp_dir,
        "lib/my_app/accounts.ex",
        "defmodule MyApp.Accounts do\n  # changed\nend"
      )

      File.touch!(Path.join(tmp_dir, "lib/my_app/accounts.ex"), :erlang.system_time(:second) + 2)

      {:ok, result} = FileSync.sync_changed(scope, base_dir: tmp_dir)
      assert result.upserted == 1
      assert "lib/my_app/accounts.ex" in result.changed_paths
      refute "lib/my_app/users.ex" in result.changed_paths
    end

    test "picks up new files not yet in DB" do
      {scope, tmp_dir} = setup_project()

      write_file(tmp_dir, "lib/my_app/accounts.ex", "defmodule MyApp.Accounts do\nend")
      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      write_file(tmp_dir, "lib/my_app/users.ex", "defmodule MyApp.Users do\nend")

      {:ok, result} = FileSync.sync_changed(scope, base_dir: tmp_dir)
      assert result.upserted == 1
      assert "lib/my_app/users.ex" in result.changed_paths
    end

    test "removes files no longer on disk" do
      {scope, tmp_dir} = setup_project()

      path = write_file(tmp_dir, "lib/my_app/old.ex", "defmodule MyApp.Old do\nend")
      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)
      assert Files.get_by_path(scope, "lib/my_app/old.ex")

      File.rm!(path)

      {:ok, result} = FileSync.sync_changed(scope, base_dir: tmp_dir)
      assert result.removed >= 1
      refute Files.get_by_path(scope, "lib/my_app/old.ex")
    end
  end

  describe "sync_path/3" do
    test "processes a single path" do
      {scope, tmp_dir} = setup_project()

      write_file(tmp_dir, "lib/my_app/accounts.ex", "defmodule MyApp.Accounts do\nend")
      write_file(tmp_dir, "lib/my_app/users.ex", "defmodule MyApp.Users do\nend")

      abs_path = Path.join(tmp_dir, "lib/my_app/accounts.ex")
      {:ok, result} = FileSync.sync_path(scope, abs_path, base_dir: tmp_dir)

      assert result.changed_path == "lib/my_app/accounts.ex"

      # Only accounts.ex should be in DB
      assert Files.get_by_path(scope, "lib/my_app/accounts.ex")
      refute Files.get_by_path(scope, "lib/my_app/users.ex")
    end

    # The watcher is what an agent rewriting a story's BDD specs actually fires,
    # and it updates the fingerprint eagerly. So by the time the stop hook's
    # pass runs, the stored fingerprint already matches the file: the entry is
    # in that pass's mtime-changed set and absent from its fingerprint-changed
    # set, which is the set the clear is keyed on. The clear lived only in the
    # stop-hook pass, so it never saw a rewrite the watcher had handled —
    # measured 2026-09-23, it had never fired once for any story on this
    # machine since it was written.
    #
    # What it cost: story 947's specs were rewritten to a new contract, the
    # latch stayed on, and its deliberately-red criterion stayed *enforced*.
    # `Promotion.gate/1` is per-copy, so that one red stopped every other story
    # promoting from the checkout, with nothing an agent could call to clear it.
    test "rewriting a story's BDD spec through the watcher clears its specs_ready latch" do
      {scope, tmp_dir} = setup_project()

      story =
        CodeMySpec.StoriesFixtures.story_fixture(scope, %{
          title: "Delegated control",
          number: 45
        })

      rel = "test/spex/45_delegated_control/criterion_3139_a_thing_happens_spex.exs"
      write_file(tmp_dir, rel, "defmodule A do\nend")
      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      {:ok, story} = CodeMySpec.Stories.set_specs_ready(scope, story, true)
      assert story.specs_ready == true

      # The contract changes. This is the event an agent's Write fires.
      abs = write_file(tmp_dir, rel, "defmodule A do\n  # a different contract\nend")
      {:ok, _} = FileSync.sync_path(scope, abs, base_dir: tmp_dir)

      assert CodeMySpec.Stories.get_story(scope, story.id).specs_ready == false,
             "a rewritten spec changes the contract, so whatever a previous " <>
               "green run proved no longer applies — and the latch is what " <>
               "decides whether this story's reds block the whole copy"
    end

    test "a byte-identical rewrite through the watcher leaves the latch alone" do
      {scope, tmp_dir} = setup_project()

      story =
        CodeMySpec.StoriesFixtures.story_fixture(scope, %{
          title: "Shipped story",
          number: 46
        })

      rel = "test/spex/46_shipped_story/criterion_4000_a_thing_happens_spex.exs"
      body = "defmodule B do\nend"
      write_file(tmp_dir, rel, body)
      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      {:ok, story} = CodeMySpec.Stories.set_specs_ready(scope, story, true)

      abs = write_file(tmp_dir, rel, body)
      {:ok, _} = FileSync.sync_path(scope, abs, base_dir: tmp_dir)

      assert CodeMySpec.Stories.get_story(scope, story.id).specs_ready == true,
             "a touch or a reformat that lands identical bytes is not a " <>
               "contract change and must not knock a shipped story out of " <>
               "enforcement — this is why the clear is keyed on the " <>
               "fingerprint-changed set rather than the mtime-changed one"
    end

    test "deletes file record when file no longer exists on disk" do
      {scope, tmp_dir} = setup_project()

      path = write_file(tmp_dir, "lib/my_app/old.ex", "defmodule MyApp.Old do\nend")

      # First create the record via full sync
      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)
      assert Files.get_by_path(scope, "lib/my_app/old.ex")

      # Delete from disk, then sync_path
      File.rm!(path)
      {:ok, result} = FileSync.sync_path(scope, path, base_dir: tmp_dir)

      assert result.changed_path == "lib/my_app/old.ex"
      refute Files.get_by_path(scope, "lib/my_app/old.ex")
    end

    # Issue 07a09cba: two working copies of the same project — a harness
    # restart briefly leaves an old and a new registration both pointed at
    # the same checkout — syncing the same path concurrently used to violate
    # `UNIQUE (files.project_id, files.path)`, before the path's uniqueness
    # was scoped to include the working copy. `upsert_file_metadata/2` now
    # targets `[:project_id, :working_copy_id, :path]`, which only matches
    # the index actually in place (20260807220000 dropped the narrower one).
    # This proves the two rows coexist instead of racing.
    test "two working copies syncing the same path do not collide" do
      {scope, tmp_dir} = setup_project()

      {:ok, second_copy} =
        WorkingCopies.issue(scope, nil, device: device_fixture(scope), root: tmp_dir)

      other_scope = %{scope | active_working_copy_id: second_copy.id}

      abs_path = write_file(tmp_dir, "lib/my_app/shared.ex", "defmodule MyApp.Shared do\nend")

      assert {:ok, _} = FileSync.sync_path(scope, abs_path, base_dir: tmp_dir)
      assert {:ok, _} = FileSync.sync_path(other_scope, abs_path, base_dir: tmp_dir)

      assert Files.get_by_path(scope, "lib/my_app/shared.ex")
      assert Files.get_by_path(other_scope, "lib/my_app/shared.ex")
    end

    test "returns nil changed_path for unrecognized file types" do
      {scope, tmp_dir} = setup_project()

      write_file(tmp_dir, "README.md", "# My App")
      abs_path = Path.join(tmp_dir, "README.md")

      {:ok, result} = FileSync.sync_path(scope, abs_path, base_dir: tmp_dir)

      assert result.changed_path == nil
    end
  end

  # -- Helpers --

  defp setup_project do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: tmp_dir})

    scope = %{
      scope
      | active_project: project,
        cwd: tmp_dir,
        environment: Environment.new(:local, tmp_dir)
    }

    # Spec-file validation is gated on `require_specs`, which a fresh project
    # now defaults off — without this the "invalid spec file" cases validate
    # leniently and come back valid, which is correct behaviour and the wrong
    # thing for these tests to be exercising.
    {CodeMySpec.ConfigurationsFixtures.ensure_configuration!(scope), tmp_dir}
  end

  defp write_file(tmp_dir, relative_path, content) do
    full_path = Path.join(tmp_dir, relative_path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
    full_path
  end
end
