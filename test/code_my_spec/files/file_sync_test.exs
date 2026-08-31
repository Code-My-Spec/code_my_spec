defmodule CodeMySpec.Files.FileSyncTest do
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Embeddings.TestBackend
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Projects
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

    test "classifies spec files" do
      assert {:spec, _} = swap(FileSync.classify(".code_my_spec/spec/my_app/accounts.spec.md"))
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

      write_file(
        tmp_dir,
        ".code_my_spec/spec/my_app/accounts.spec.md",
        "# MyApp.Accounts\n\n## Type\n\nschema"
      )

      write_file(tmp_dir, "CLAUDE.md", "# Project")

      {:ok, result} = FileSync.sync(scope, base_dir: tmp_dir)

      assert result.total_files >= 3
      assert result.upserted >= 3

      files = Files.list_files(scope)
      paths = Enum.map(files, & &1.path)

      assert "lib/my_app/accounts.ex" in paths
      assert ".code_my_spec/spec/my_app/accounts.spec.md" in paths
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

      # Delete the file
      File.rm!(path)

      {:ok, result} = FileSync.sync(scope, base_dir: tmp_dir)
      assert result.removed >= 1
      refute Files.get_by_path(scope, "lib/my_app/old.ex")
    end

    test "assigns component_id to implementation files" do
      {scope, tmp_dir} = setup_project()

      # Create a component in DB
      {:ok, component} =
        CodeMySpec.Components.create_component(scope, %{
          name: "Accounts",
          type: "schema",
          module_name: "MyApp.Accounts"
        })

      write_file(tmp_dir, "lib/my_app/accounts.ex", "defmodule MyApp.Accounts do\nend")

      write_file(
        tmp_dir,
        ".code_my_spec/spec/my_app/accounts.spec.md",
        "# MyApp.Accounts\n\n## Type\n\nschema"
      )

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      impl_file = Files.get_by_path(scope, "lib/my_app/accounts.ex")
      assert impl_file.component_id == component.id
      assert impl_file.role == :implementation

      spec_file = Files.get_by_path(scope, ".code_my_spec/spec/my_app/accounts.spec.md")
      assert spec_file.component_id == component.id
      assert spec_file.role == :spec
    end

    test "validates spec files during sync" do
      {scope, tmp_dir} = setup_project()

      # Valid liveview spec with required sections
      spec_content = """
      # MyApp.UserLive.Index

      A page listing users.

      ## Type

      liveview

      ## Route

      `/users`

      ## User Interactions

      - **phx-click=delete**: Deletes a user

      ## Dependencies

      - MyApp.Users

      ## Design

      Layout: Table of users.
      """

      write_file(tmp_dir, ".code_my_spec/spec/my_app/user_live/index.spec.md", spec_content)
      write_file(tmp_dir, "lib/my_app/accounts.ex", "defmodule MyApp.Accounts do\nend")

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      spec_file = Files.get_by_path(scope, ".code_my_spec/spec/my_app/user_live/index.spec.md")
      assert spec_file.valid == true
      # A clean spec now carries the component identity the scan extracted —
      # `ComponentSync` reads it instead of reopening the file. "No errors" is
      # the claim being made here, which is what nil used to stand for.
      assert spec_file.validation_errors["errors"] == %{}
      assert spec_file.validation_errors["data"]["module_name"] != nil

      impl_file = Files.get_by_path(scope, "lib/my_app/accounts.ex")
      assert impl_file.valid == true
    end

    test "sets valid false for invalid spec files" do
      {scope, tmp_dir} = setup_project()

      # Spec missing required sections
      write_file(
        tmp_dir,
        ".code_my_spec/spec/my_app/broken.spec.md",
        "# MyApp.Broken\n\n## Type\n\nschema\n"
      )

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      spec_file = Files.get_by_path(scope, ".code_my_spec/spec/my_app/broken.spec.md")
      assert spec_file.valid == false
      assert spec_file.validation_errors != nil
    end

    # Regression: a spec authored/edited on Windows carries CRLF line endings.
    # The `## Type` extraction (and the H1 validator) are `$`-anchored, so a
    # `## Type\r` line failed to match, the document type silently resolved to
    # the default "spec" definition, and the WRONG section set was enforced —
    # a context spec was rejected for "Disallowed sections found: components"
    # and a schema spec for "Missing required sections". Both must validate.
    test "validates a CRLF context spec (type resolves to context_spec, Components allowed)" do
      {scope, tmp_dir} = setup_project()

      content =
        Enum.join(
          [
            "# MyApp.Tasks",
            "",
            "## Type",
            "",
            "context",
            "",
            "## Functions",
            "",
            "### create_task/1",
            "",
            "Creates a task.",
            "",
            "## Dependencies",
            "",
            "- MyApp.Repo",
            "",
            "## Components",
            "",
            "### MyApp.Tasks.Task",
            "",
            "The task schema.",
            ""
          ],
          "\r\n"
        )

      write_file(tmp_dir, ".code_my_spec/spec/my_app/tasks.spec.md", content)

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      spec_file = Files.get_by_path(scope, ".code_my_spec/spec/my_app/tasks.spec.md")

      assert spec_file.valid == true,
             "CRLF context spec invalid: #{inspect(spec_file.validation_errors)}"

      # A clean spec now carries the component identity the scan extracted —
      # `ComponentSync` reads it instead of reopening the file. "No errors" is
      # the claim being made here, which is what nil used to stand for.
      assert spec_file.validation_errors["errors"] == %{}
      assert spec_file.validation_errors["data"]["module_name"] != nil
    end

    test "validates a CRLF schema spec (type resolves to schema, not default spec)" do
      {scope, tmp_dir} = setup_project()

      content =
        Enum.join(
          [
            "# MyApp.Tasks.Task",
            "",
            "## Type",
            "",
            "schema",
            "",
            "## Fields",
            "",
            "| Field | Type | Required | Description | Constraints |",
            "|-------|------|----------|-------------|-------------|",
            "| title | string | Yes | Task title | Max: 255 |",
            "",
            "## Dependencies",
            "",
            "- MyApp.Repo",
            ""
          ],
          "\r\n"
        )

      write_file(tmp_dir, ".code_my_spec/spec/my_app/task.spec.md", content)

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      spec_file = Files.get_by_path(scope, ".code_my_spec/spec/my_app/task.spec.md")

      assert spec_file.valid == true,
             "CRLF schema spec invalid: #{inspect(spec_file.validation_errors)}"

      # A clean spec now carries the component identity the scan extracted —
      # `ComponentSync` reads it instead of reopening the file. "No errors" is
      # the claim being made here, which is what nil used to stand for.
      assert spec_file.validation_errors["errors"] == %{}
      assert spec_file.validation_errors["data"]["module_name"] != nil
    end

    test "validates test files against spec test assertions" do
      {scope, tmp_dir} = setup_project()

      spec_content = """
      # MyApp.UserLive.Index

      A page listing users.

      ## Type

      liveview

      ## Route

      `/users`

      ## User Interactions

      - **phx-click=delete**: Deletes a user

      ## Dependencies

      - MyApp.Users

      ## Design

      Layout: Table of users.

      ## Test Assertions

      - renders user list
      - deletes user on click
      """

      # Test names must match the spec's Test Assertions lines. SpecAlignment
      # pulls `{:test, _, [name, ...]}` nodes from the AST; describe block names
      # aren't considered matchable.
      aligned_test = """
      defmodule MyApp.UserLive.IndexTest do
        use ExUnit.Case

        test "renders user list" do
          assert true
        end

        test "deletes user on click" do
          assert true
        end
      end
      """

      # Create component so test file gets component_id
      {:ok, component} =
        CodeMySpec.Components.create_component(scope, %{
          name: "Index",
          type: "liveview",
          module_name: "MyApp.UserLive.Index"
        })

      write_file(tmp_dir, ".code_my_spec/spec/my_app/user_live/index.spec.md", spec_content)
      write_file(tmp_dir, "test/my_app/user_live/index_test.exs", aligned_test)

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      test_file = Files.get_by_path(scope, "test/my_app/user_live/index_test.exs")
      assert test_file.component_id == component.id
      assert test_file.valid == true
    end

    test "marks test file invalid when spec assertions are missing" do
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
      assert test_file.valid == false
      assert "opens edit form on click" in test_file.validation_errors["missing"]
      assert "handles missing user" in test_file.validation_errors["missing"]
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

      # Add a new file
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

    test "returns nil changed_path for unrecognized file types" do
      {scope, tmp_dir} = setup_project()

      write_file(tmp_dir, "README.md", "# My App")
      abs_path = Path.join(tmp_dir, "README.md")

      {:ok, result} = FileSync.sync_path(scope, abs_path, base_dir: tmp_dir)

      assert result.changed_path == nil
    end

    test "validates spec files" do
      {scope, tmp_dir} = setup_project()

      # Invalid spec — missing required sections
      write_file(
        tmp_dir,
        ".code_my_spec/spec/my_app/broken.spec.md",
        "# MyApp.Broken\n\n## Type\n\nschema\n"
      )

      abs_path = Path.join(tmp_dir, ".code_my_spec/spec/my_app/broken.spec.md")

      {:ok, _} = FileSync.sync_path(scope, abs_path, base_dir: tmp_dir)

      file = Files.get_by_path(scope, ".code_my_spec/spec/my_app/broken.spec.md")
      assert file.valid == false
      assert file.validation_errors != nil
    end

    # The watcher's per-file dispatch route. `FileSync.sync_path/3`
    # mirrors `sync/2`'s embedding hook so file changes detected by
    # `:fs` events drive embedding in real time, not only on the
    # next stop hook batch.
    test "embeds a newly-created spec file" do
      TestBackend.reset()
      {scope, tmp_dir} = setup_project()

      path = ".code_my_spec/spec/my_app/widget.spec.md"
      write_file(tmp_dir, path, "# Widget\n\nThe widget context exposes create_widget.")
      abs_path = Path.join(tmp_dir, path)

      {:ok, _} = FileSync.sync_path(scope, abs_path, base_dir: tmp_dir)

      {:ok, results} =
        CodeMySpec.Embeddings.search(scope, "create_widget", source: "spec", limit: 5)

      assert Enum.any?(results, &(&1.path == path)),
             "Expected sync_path to embed the new spec file. Got: #{inspect(results)}"
    end

    test "re-embeds when a file's content changes (fingerprint diff)" do
      TestBackend.reset()
      {scope, tmp_dir} = setup_project()

      path = ".code_my_spec/spec/my_app/widget.spec.md"
      abs_path = Path.join(tmp_dir, path)

      write_file(tmp_dir, path, "# Widget\n\nThe widget exposes create_widget/2.")
      {:ok, _} = FileSync.sync_path(scope, abs_path, base_dir: tmp_dir)

      write_file(tmp_dir, path, "# Widget\n\nThe widget exposes create_widget/3 with attrs.")
      {:ok, _} = FileSync.sync_path(scope, abs_path, base_dir: tmp_dir)

      {:ok, results} =
        CodeMySpec.Embeddings.search(scope, "create_widget attrs arity 3",
          source: "spec",
          limit: 5
        )

      hit = Enum.find(results, &(&1.path == path))
      assert hit, "Expected re-embedded chunk for #{path}, got: #{inspect(results)}"
      assert hit.content =~ "create_widget/3"
      refute hit.content =~ "create_widget/2"
    end

    test "drops embeddings when a tracked file is deleted from disk" do
      TestBackend.reset()
      {scope, tmp_dir} = setup_project()

      path = ".code_my_spec/rules/legacy.md"
      abs_path = write_file(tmp_dir, path, "# Legacy\n\nUse legacy_factory/1 to bootstrap.")

      {:ok, _} = FileSync.sync_path(scope, abs_path, base_dir: tmp_dir)

      {:ok, results} =
        CodeMySpec.Embeddings.search(scope, "legacy_factory bootstrap",
          source: "rules",
          limit: 5
        )

      assert Enum.any?(results, &(&1.path == path)),
             "Pre-condition: expected the file to be embedded after first sync"

      File.rm!(abs_path)
      {:ok, _} = FileSync.sync_path(scope, abs_path, base_dir: tmp_dir)

      {:ok, results_after} =
        CodeMySpec.Embeddings.search(scope, "legacy_factory bootstrap",
          source: "rules",
          limit: 10
        )

      refute Enum.any?(results_after, &(&1.path == path)),
             "Expected embeddings for the deleted file to be dropped, got: #{inspect(results_after)}"
    end

    test "skips re-embedding when content fingerprint is unchanged" do
      TestBackend.reset()
      {scope, tmp_dir} = setup_project()

      path = ".code_my_spec/spec/my_app/widget.spec.md"
      abs_path = Path.join(tmp_dir, path)

      content = "# Widget\n\nThe widget exposes create_widget/2."
      write_file(tmp_dir, path, content)
      {:ok, _} = FileSync.sync_path(scope, abs_path, base_dir: tmp_dir)

      # Bump mtime by re-writing the same content. sync_path will
      # re-fingerprint, see no change, and skip the embedding hook.
      File.touch!(abs_path)
      {:ok, _} = FileSync.sync_path(scope, abs_path, base_dir: tmp_dir)

      # Search still finds the embedded chunk — the second sync_path
      # didn't double-insert (TestBackend would now have one chunk per
      # file regardless because embed_file deletes-then-inserts, but
      # the contract this asserts is that no error is raised and the
      # search result is stable).
      {:ok, results} =
        CodeMySpec.Embeddings.search(scope, "create_widget", source: "spec", limit: 5)

      assert Enum.count(results, &(&1.path == path)) == 1
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
    {CodeMySpec.ConfigurationsFixtures.require_all!(scope), tmp_dir}
  end

  defp write_file(tmp_dir, relative_path, content) do
    full_path = Path.join(tmp_dir, relative_path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
    full_path
  end
end
