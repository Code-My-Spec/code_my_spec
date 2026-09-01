defmodule CodeMySpec.ProjectsTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Projects

  describe "projects" do
    alias CodeMySpec.Projects.Project

    import CodeMySpec.UsersFixtures, only: [user_fixture: 0, user_scope_fixture: 2]
    import CodeMySpec.AccountsFixtures, only: [account_with_owner_fixture: 1]
    import CodeMySpec.ProjectsFixtures

    @invalid_attrs %{
      name: nil,
      description: nil,
      status: nil,
      code_repo: nil,
      docs_repo: nil,
      setup_error: nil
    }

    test "resolve_local_project/1 matches on working dir when no project is configured" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope, %{local_path: "/home/dev/alpha"})

      assert {:ok, found} = Projects.resolve_local_project("/home/dev/alpha")
      assert found.id == project.id

      assert {:error, :not_found} = Projects.resolve_local_project("/home/dev/nope")
    end

    test "resolve_local_project/1 reads project_id from the project's own config" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)

      # The project's local_path is deliberately somewhere else, so a pass only
      # happens if the config file was consulted rather than the directory.
      project = project_fixture(scope, %{local_path: "/somewhere/else"})
      dir = write_config(%{"project_id" => project.id})

      assert {:ok, found} = Projects.resolve_local_project(dir)
      assert found.id == project.id
    end

    test "resolve_local_project/1 prefers the configured project over the config file" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)

      sprite_project = project_fixture(scope, %{local_path: "/workspace/app"})
      other = project_fixture(scope, %{local_path: "/somewhere/else"})
      dir = write_config(%{"project_id" => other.id})

      Application.put_env(:code_my_spec, :project_id, sprite_project.id)
      on_exit(fn -> Application.delete_env(:code_my_spec, :project_id) end)

      # A sprite is told what it is. A config file it happens to have cloned
      # must not talk it out of that.
      assert {:ok, found} = Projects.resolve_local_project(dir)
      assert found.id == sprite_project.id
    end

    test "resolve_local_project/1 falls back to the working dir with no config" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)

      {:ok, dir} = Briefly.create(directory: true)
      project = project_fixture(scope, %{local_path: dir})

      assert {:ok, found} = Projects.resolve_local_project(dir)
      assert found.id == project.id
    end

    test "resolve_local_project/1 refuses a config naming a project that does not exist" do
      dir = write_config(%{"project_id" => Ecto.UUID.generate()})

      # Deliberately not a fall-through to the path lookup: a config file naming
      # an unknown project is a mistake, and silently binding the directory to
      # whatever else matches would hide it.
      assert {:error, :not_found} = Projects.resolve_local_project(dir)
    end

    test "resolve_local_project/1 ignores the working dir when a project is configured" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)

      # Two checkouts of different projects that landed on the same conventional
      # path — `/workspace/<app>` is the same string in every container.
      mine = project_fixture(scope, %{local_path: "/workspace/app"})
      _theirs = project_fixture(scope, %{local_path: "/workspace/app"})

      Application.put_env(:code_my_spec, :project_id, mine.id)
      on_exit(fn -> Application.delete_env(:code_my_spec, :project_id) end)

      # Without config this is `order_by updated_at desc, limit 1` — it returns
      # a project, just not reliably the right one. Configured, the collision
      # cannot arise because the directory is never consulted.
      assert {:ok, found} = Projects.resolve_local_project("/workspace/app")
      assert found.id == mine.id

      # Even a directory belonging to nothing resolves, because identity does
      # not come from the directory.
      assert {:ok, ^found} = Projects.resolve_local_project("/some/other/dir")
      assert {:ok, ^found} = Projects.resolve_local_project(nil)
    end

    test "deploy_key is encrypted at rest" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)

      plaintext = "plaintext-deploy-key-secret"
      project = project_fixture(scope, %{deploy_key: plaintext})

      %{rows: [[stored]]} =
        CodeMySpec.Repo.query!("SELECT deploy_key FROM projects WHERE id = $1", [
          Ecto.UUID.dump!(project.id)
        ])

      assert is_binary(stored)

      assert :binary.match(stored, plaintext) == :nomatch,
             "deploy_key must be stored as ciphertext, not plaintext"

      # Reading back through the schema decrypts transparently.
      assert Projects.get_project!(scope, project.id).deploy_key == plaintext
    end

    test "reusing another project's deploy key returns an error, not a constraint crash" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)

      shared_key = "shared-deploy-key-secret"
      project_fixture(scope, %{deploy_key: shared_key})
      other = project_fixture(scope, %{deploy_key: "a-different-key"})

      assert {:error, changeset} = Projects.update_project(scope, other, %{deploy_key: shared_key})

      assert "is already in use by another project" in errors_on(changeset).deploy_key
    end

    test "list_local_account_ids/0 skips local projects with a nil account_id" do
      # A local project whose account_id is nil (reachable when a project is
      # created under a scope with no active account) must not surface as a nil
      # in the account list — SocketSupervisor feeds each id into
      # first_local_project_for_account/1, and Ecto raises on `== nil`, which
      # crash-loops the whole local server at boot.
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)

      project_fixture(scope, %{local_path: "/tmp/good"})
      orphan = project_fixture(scope, %{local_path: "/tmp/orphan"})

      {1, _} =
        Repo.update_all(from(p in Project, where: p.id == ^orphan.id),
          set: [account_id: nil]
        )

      ids = Projects.list_local_account_ids()

      refute nil in ids
      assert account.id in ids
    end

    test "first_local_project_for_account/1 returns nil for a nil account without raising" do
      assert Projects.first_local_project_for_account(nil) == nil
    end

    test "list_projects/1 returns all scoped projects" do
      user = user_fixture()
      other_user = user_fixture()
      account = account_with_owner_fixture(user)
      other_account = account_with_owner_fixture(other_user)
      scope = user_scope_fixture(user, account)
      other_scope = user_scope_fixture(other_user, other_account)
      project = project_fixture(scope)
      other_project = project_fixture(other_scope)
      assert Projects.list_projects(scope) == [project]
      assert Projects.list_projects(other_scope) == [other_project]
    end

    test "get_project!/2 returns the project with given id" do
      user = user_fixture()
      other_user = user_fixture()
      account = account_with_owner_fixture(user)
      other_account = account_with_owner_fixture(other_user)
      scope = user_scope_fixture(user, account)
      other_scope = user_scope_fixture(other_user, other_account)
      project = project_fixture(scope)
      assert Projects.get_project!(scope, project.id) == project
      assert_raise Ecto.NoResultsError, fn -> Projects.get_project!(other_scope, project.id) end
    end

    test "create_project/2 with valid data creates a project" do
      valid_attrs = %{
        name: "some name",
        description: "some description",
        status: :created,
        code_repo: "some code_repo",
        docs_repo: "some docs_repo",
        setup_error: "some setup_error"
      }

      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)

      assert {:ok, %Project{} = project} = Projects.create_project(scope, valid_attrs)
      assert project.name == "some name"
      assert project.description == "some description"
      assert project.status == :created
      assert project.code_repo == "some code_repo"
      assert project.docs_repo == "some docs_repo"
      assert project.setup_error == "some setup_error"
      assert project.account_id == account.id
    end

    # A key is what a harness presents to join a project's channel, so a project
    # without one has a first checkout that cannot join: the daemon falls back
    # to whatever key it was started with, which belongs to a different project,
    # and the join is refused. QA 963 hit exactly that on a project made through
    # the form, and nothing on the way named the missing key.
    test "create_project/2 mints a deploy key, so the project's first checkout can join" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)

      assert {:ok, %Project{} = project} =
               Projects.create_project(scope, %{name: "keyed", module_name: "Keyed"})

      assert is_binary(project.deploy_key) and project.deploy_key != "",
             "a project created with no key has a checkout that cannot authenticate as it"

      assert String.starts_with?(project.deploy_key, "dk_")
    end

    test "create_project/2 keeps a deploy key the caller supplied" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)

      assert {:ok, %Project{} = project} =
               Projects.create_project(scope, %{
                 name: "byo",
                 module_name: "Byo",
                 deploy_key: "dk_supplied"
               })

      assert project.deploy_key == "dk_supplied",
             "minting over a key the caller gave would invalidate whatever already holds it"
    end

    test "create_project/2 with invalid data returns error changeset" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      assert {:error, %Ecto.Changeset{}} = Projects.create_project(scope, @invalid_attrs)
    end

    test "update_project/3 with valid data updates the project" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)

      update_attrs = %{
        name: "some updated name",
        description: "some updated description",
        status: :created,
        code_repo: "some updated code_repo",
        docs_repo: "some updated docs_repo",
        setup_error: "some updated setup_error"
      }

      assert {:ok, %Project{} = project} = Projects.update_project(scope, project, update_attrs)
      assert project.name == "some updated name"
      assert project.description == "some updated description"
      assert project.status == :created
      assert project.code_repo == "some updated code_repo"
      assert project.docs_repo == "some updated docs_repo"
      assert project.setup_error == "some updated setup_error"
    end

    test "update_project/3 with invalid scope raises" do
      user = user_fixture()
      other_user = user_fixture()
      account = account_with_owner_fixture(user)
      other_account = account_with_owner_fixture(other_user)
      scope = user_scope_fixture(user, account)
      other_scope = user_scope_fixture(other_user, other_account)
      project = project_fixture(scope)

      assert_raise MatchError, fn ->
        Projects.update_project(other_scope, project, %{})
      end
    end

    test "update_project/3 with invalid data returns error changeset" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)
      assert {:error, %Ecto.Changeset{}} = Projects.update_project(scope, project, @invalid_attrs)
      assert project == Projects.get_project!(scope, project.id)
    end

    test "delete_project/2 deletes the project" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)
      assert {:ok, %Project{}} = Projects.delete_project(scope, project)
      assert_raise Ecto.NoResultsError, fn -> Projects.get_project!(scope, project.id) end
    end

    test "delete_project/2 with invalid scope raises" do
      user = user_fixture()
      other_user = user_fixture()
      account = account_with_owner_fixture(user)
      other_account = account_with_owner_fixture(other_user)
      scope = user_scope_fixture(user, account)
      other_scope = user_scope_fixture(other_user, other_account)
      project = project_fixture(scope)
      assert_raise MatchError, fn -> Projects.delete_project(other_scope, project) end
    end

    test "change_project/2 returns a project changeset" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)
      assert %Ecto.Changeset{} = Projects.change_project(scope, project)
    end

    test "create_github_repo/4 returns error when GitHub not connected" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)

      project =
        project_fixture(scope, %{
          name: "Test Project",
          description: "A test project"
        })

      # Without GitHub integration, should return error
      assert {:error, :github_not_connected} =
               Projects.create_github_repo(scope, project, :code_repo, %{}, "-code")
    end
  end

  # A project root carrying `.code_my_spec/config.yml`, the way a real checkout
  # does. Briefly cleans it up.
  defp write_config(config) do
    {:ok, dir} = Briefly.create(directory: true)
    File.mkdir_p!(Path.join(dir, ".code_my_spec"))

    yaml = Enum.map_join(config, "\n", fn {k, v} -> "#{k}: #{v}" end)
    File.write!(Path.join([dir, ".code_my_spec", "config.yml"]), yaml <> "\n")

    dir
  end
end
