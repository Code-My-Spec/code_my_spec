defmodule CodeMySpec.ProjectSync.StatusWriterTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.ProjectSync.StatusWriter
  alias CodeMySpec.Requirements.Requirement

  @moduletag :unit

  defp build_component(attrs) do
    defaults = %{
      id: Ecto.UUID.generate(),
      name: "Test",
      module_name: "MyApp.Test",
      type: "module",
      parent_component_id: nil,
      child_components: [],
      requirements: []
    }

    struct(Component, Map.merge(defaults, attrs))
  end

  defp build_requirement(attrs) do
    defaults = %{
      name: "spec_file",
      description: "Specification file exists",
      satisfied: false,
      artifact_type: :specification
    }

    struct(Requirement, Map.merge(defaults, attrs))
  end

  defp build_env(tmp_dir) do
    Environment.new(:local, tmp_dir)
  end

  describe "write_status_files/2" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "status_writer_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, tmp_dir: tmp_dir, env: build_env(tmp_dir)}
    end

    test "writes root summary and one file per context", %{tmp_dir: tmp_dir, env: env} do
      accounts =
        build_component(%{name: "Accounts", module_name: "MyApp.Accounts", type: "context"})

      billing = build_component(%{name: "Billing", module_name: "MyApp.Billing", type: "context"})

      app =
        build_component(%{
          name: "MyApp",
          module_name: "MyApp",
          type: "module",
          child_components: [accounts, billing]
        })

      result = StatusWriter.write_status_files([app], env)

      assert "docs/status/my_app.md" in result
      assert "docs/status/my_app/accounts.md" in result
      assert "docs/status/my_app/billing.md" in result

      assert File.exists?(Path.join(tmp_dir, "docs/status/my_app.md"))
      assert File.exists?(Path.join(tmp_dir, "docs/status/my_app/accounts.md"))
      assert File.exists?(Path.join(tmp_dir, "docs/status/my_app/billing.md"))
    end

    test "renders descendants inline in context file", %{tmp_dir: tmp_dir, env: env} do
      user =
        build_component(%{
          name: "User",
          module_name: "MyApp.Accounts.User",
          type: "schema"
        })

      accounts =
        build_component(%{
          name: "Accounts",
          module_name: "MyApp.Accounts",
          type: "context",
          child_components: [user]
        })

      app =
        build_component(%{
          name: "MyApp",
          module_name: "MyApp",
          type: "module",
          child_components: [accounts]
        })

      result = StatusWriter.write_status_files([app], env)

      assert "docs/status/my_app.md" in result
      assert "docs/status/my_app/accounts.md" in result

      # User is rendered inline in accounts file, not as a separate file
      content = File.read!(Path.join(tmp_dir, "docs/status/my_app/accounts.md"))
      assert content =~ "## MyApp.Accounts.User (schema)"
    end

    test "root summary includes contexts section with links", %{tmp_dir: tmp_dir, env: env} do
      user = build_component(%{name: "User", module_name: "MyApp.Accounts.User", type: "schema"})

      accounts =
        build_component(%{
          name: "Accounts",
          module_name: "MyApp.Accounts",
          type: "context",
          child_components: [user]
        })

      app =
        build_component(%{
          name: "MyApp",
          module_name: "MyApp",
          type: "module",
          child_components: [accounts]
        })

      StatusWriter.write_status_files([app], env)

      content = File.read!(Path.join(tmp_dir, "docs/status/my_app.md"))
      assert content =~ "## Contexts"
      assert content =~ "[MyApp.Accounts]"
    end

    test "renders satisfied requirements with checked boxes", %{tmp_dir: tmp_dir, env: env} do
      req =
        build_requirement(%{
          name: "spec_file",
          description: "Specification file exists",
          satisfied: true
        })

      context =
        build_component(%{
          name: "Accounts",
          module_name: "MyApp.Accounts",
          type: "context",
          requirements: [req]
        })

      app =
        build_component(%{
          name: "MyApp",
          module_name: "MyApp",
          type: "module",
          child_components: [context]
        })

      StatusWriter.write_status_files([app], env)

      content = File.read!(Path.join(tmp_dir, "docs/status/my_app/accounts.md"))
      assert content =~ "- [x] spec_file - Specification file exists"
    end

    test "renders unsatisfied requirements with unchecked boxes", %{tmp_dir: tmp_dir, env: env} do
      req =
        build_requirement(%{name: "test_file", description: "Test file exists", satisfied: false})

      context =
        build_component(%{
          name: "Accounts",
          module_name: "MyApp.Accounts",
          type: "context",
          requirements: [req]
        })

      app =
        build_component(%{
          name: "MyApp",
          module_name: "MyApp",
          type: "module",
          child_components: [context]
        })

      StatusWriter.write_status_files([app], env)

      content = File.read!(Path.join(tmp_dir, "docs/status/my_app/accounts.md"))
      assert content =~ "- [ ] test_file - Test file exists"
    end

    test "renders multiple requirements in order", %{tmp_dir: tmp_dir, env: env} do
      reqs = [
        build_requirement(%{name: "spec_file", description: "Spec exists", satisfied: true}),
        build_requirement(%{name: "test_file", description: "Test exists", satisfied: false}),
        build_requirement(%{name: "impl_file", description: "Impl exists", satisfied: true})
      ]

      context =
        build_component(%{
          name: "Accounts",
          module_name: "MyApp.Accounts",
          type: "context",
          requirements: reqs
        })

      app =
        build_component(%{
          name: "MyApp",
          module_name: "MyApp",
          type: "module",
          child_components: [context]
        })

      StatusWriter.write_status_files([app], env)

      content = File.read!(Path.join(tmp_dir, "docs/status/my_app/accounts.md"))
      assert content =~ "- [x] spec_file - Spec exists"
      assert content =~ "- [ ] test_file - Test exists"
      assert content =~ "- [x] impl_file - Impl exists"
    end

    test "shows placeholder for components with no requirements", %{tmp_dir: tmp_dir, env: env} do
      context =
        build_component(%{
          name: "Accounts",
          module_name: "MyApp.Accounts",
          type: "context"
        })

      app =
        build_component(%{
          name: "MyApp",
          module_name: "MyApp",
          type: "module",
          child_components: [context]
        })

      StatusWriter.write_status_files([app], env)

      content = File.read!(Path.join(tmp_dir, "docs/status/my_app/accounts.md"))
      assert content =~ "_No requirements defined_"
    end

    test "overwrites existing status files without cleaning up unrelated files", %{
      tmp_dir: tmp_dir,
      env: env
    } do
      status_dir = Path.join(tmp_dir, "docs/status")
      File.mkdir_p!(status_dir)

      File.write!(Path.join(status_dir, "stale.md"), "stale")
      File.write!(Path.join(status_dir, ".gitkeep"), "")

      context =
        build_component(%{
          name: "Accounts",
          module_name: "MyApp.Accounts",
          type: "context"
        })

      app =
        build_component(%{
          name: "MyApp",
          module_name: "MyApp",
          type: "module",
          child_components: [context]
        })

      StatusWriter.write_status_files([app], env)

      assert File.exists?(Path.join(tmp_dir, "docs/status/my_app/accounts.md"))
      assert File.exists?(Path.join(status_dir, "stale.md"))
      assert File.exists?(Path.join(status_dir, ".gitkeep"))
    end

    test "handles empty component list", %{env: env} do
      result = StatusWriter.write_status_files([], env)
      assert result == []
    end

    test "includes type in component section header", %{tmp_dir: tmp_dir, env: env} do
      context =
        build_component(%{
          name: "Accounts",
          module_name: "MyApp.Accounts",
          type: "context"
        })

      app =
        build_component(%{
          name: "MyApp",
          module_name: "MyApp",
          type: "module",
          child_components: [context]
        })

      StatusWriter.write_status_files([app], env)

      content = File.read!(Path.join(tmp_dir, "docs/status/my_app/accounts.md"))
      assert content =~ "## MyApp.Accounts (context)"
    end

    test "deep nesting renders all descendants inline in context file", %{
      tmp_dir: tmp_dir,
      env: env
    } do
      behaviour =
        build_component(%{
          name: "Behaviour",
          module_name: "MyApp.Integrations.Providers.Behaviour",
          type: "module"
        })

      providers =
        build_component(%{
          name: "Providers",
          module_name: "MyApp.Integrations.Providers",
          type: "module",
          child_components: [behaviour]
        })

      integrations =
        build_component(%{
          name: "Integrations",
          module_name: "MyApp.Integrations",
          type: "context",
          child_components: [providers]
        })

      app =
        build_component(%{
          name: "MyApp",
          module_name: "MyApp",
          type: "module",
          child_components: [integrations]
        })

      result = StatusWriter.write_status_files([app], env)

      assert "docs/status/my_app.md" in result
      assert "docs/status/my_app/integrations.md" in result

      content = File.read!(Path.join(tmp_dir, "docs/status/my_app/integrations.md"))
      assert content =~ "## MyApp.Integrations (context)"
      assert content =~ "## MyApp.Integrations.Providers (module)"
      assert content =~ "## MyApp.Integrations.Providers.Behaviour (module)"
    end

    test "root summary shows completion checkboxes with counts", %{tmp_dir: tmp_dir, env: env} do
      accounts =
        build_component(%{
          name: "Accounts",
          module_name: "MyApp.Accounts",
          type: "context",
          requirements: [
            build_requirement(%{name: "spec", description: "Spec", satisfied: true}),
            build_requirement(%{name: "test", description: "Test", satisfied: true})
          ]
        })

      billing =
        build_component(%{
          name: "Billing",
          module_name: "MyApp.Billing",
          type: "context",
          requirements: [
            build_requirement(%{name: "spec", description: "Spec", satisfied: true}),
            build_requirement(%{name: "test", description: "Test", satisfied: false})
          ]
        })

      app =
        build_component(%{
          name: "MyApp",
          module_name: "MyApp",
          type: "module",
          child_components: [accounts, billing]
        })

      StatusWriter.write_status_files([app], env)

      content = File.read!(Path.join(tmp_dir, "docs/status/my_app.md"))
      assert content =~ "- [x] [MyApp.Accounts]"
      assert content =~ "(2/2)"
      assert content =~ "- [ ] [MyApp.Billing]"
      assert content =~ "(1/2)"
    end

    test "completion counts include descendant requirements", %{tmp_dir: tmp_dir, env: env} do
      user =
        build_component(%{
          name: "User",
          module_name: "MyApp.Accounts.User",
          type: "schema",
          requirements: [
            build_requirement(%{name: "spec", description: "Spec", satisfied: true}),
            build_requirement(%{name: "test", description: "Test", satisfied: true})
          ]
        })

      accounts =
        build_component(%{
          name: "Accounts",
          module_name: "MyApp.Accounts",
          type: "context",
          child_components: [user],
          requirements: [
            build_requirement(%{name: "spec", description: "Spec", satisfied: true})
          ]
        })

      app =
        build_component(%{
          name: "MyApp",
          module_name: "MyApp",
          type: "module",
          child_components: [accounts]
        })

      StatusWriter.write_status_files([app], env)

      content = File.read!(Path.join(tmp_dir, "docs/status/my_app.md"))
      # 3 total: 1 on context + 2 on User descendant, all satisfied
      assert content =~ "- [x] [MyApp.Accounts]"
      assert content =~ "(3/3)"
    end

    test "no-requirements context shows unchecked with 0/0", %{tmp_dir: tmp_dir, env: env} do
      accounts =
        build_component(%{
          name: "Accounts",
          module_name: "MyApp.Accounts",
          type: "context"
        })

      app =
        build_component(%{
          name: "MyApp",
          module_name: "MyApp",
          type: "module",
          child_components: [accounts]
        })

      StatusWriter.write_status_files([app], env)

      content = File.read!(Path.join(tmp_dir, "docs/status/my_app.md"))
      assert content =~ "- [ ] [MyApp.Accounts]"
      assert content =~ "(0/0)"
    end

    test "ignored components excluded from root summary and context files", %{
      tmp_dir: tmp_dir,
      env: env
    } do
      repo =
        build_component(%{
          name: "Repo",
          module_name: "MyApp.Repo",
          type: "module"
        })

      user =
        build_component(%{
          name: "User",
          module_name: "MyApp.Accounts.User",
          type: "schema"
        })

      accounts =
        build_component(%{
          name: "Accounts",
          module_name: "MyApp.Accounts",
          type: "context",
          child_components: [user]
        })

      app =
        build_component(%{
          name: "MyApp",
          module_name: "MyApp",
          type: "module",
          child_components: [repo, accounts]
        })

      result = StatusWriter.write_status_files([app], env, ignored_components: ["Repo"])

      root_content = File.read!(Path.join(tmp_dir, "docs/status/my_app.md"))
      refute root_content =~ "Repo"
      assert root_content =~ "[MyApp.Accounts]"

      # Repo should not get its own context file
      refute "docs/status/my_app/repo.md" in result
    end

    test "ignored descendants excluded from context files", %{tmp_dir: tmp_dir, env: env} do
      repo =
        build_component(%{
          name: "Repo",
          module_name: "MyApp.Accounts.Repo",
          type: "module",
          requirements: [
            build_requirement(%{name: "spec", description: "Spec", satisfied: false})
          ]
        })

      user =
        build_component(%{
          name: "User",
          module_name: "MyApp.Accounts.User",
          type: "schema",
          requirements: [
            build_requirement(%{name: "spec", description: "Spec", satisfied: true})
          ]
        })

      accounts =
        build_component(%{
          name: "Accounts",
          module_name: "MyApp.Accounts",
          type: "context",
          child_components: [repo, user],
          requirements: [
            build_requirement(%{name: "spec", description: "Spec", satisfied: true})
          ]
        })

      app =
        build_component(%{
          name: "MyApp",
          module_name: "MyApp",
          type: "module",
          child_components: [accounts]
        })

      StatusWriter.write_status_files([app], env, ignored_components: ["Repo"])

      context_content = File.read!(Path.join(tmp_dir, "docs/status/my_app/accounts.md"))
      refute context_content =~ "Repo"
      assert context_content =~ "## MyApp.Accounts.User (schema)"

      # Completion counts should exclude Repo's unsatisfied requirement
      root_content = File.read!(Path.join(tmp_dir, "docs/status/my_app.md"))
      assert root_content =~ "(2/2)"
      assert root_content =~ "[x]"
    end
  end

  describe "context_completion/1" do
    test "returns {satisfied, total} for context with requirements" do
      context =
        build_component(%{
          name: "Accounts",
          module_name: "MyApp.Accounts",
          type: "context",
          requirements: [
            build_requirement(%{satisfied: true}),
            build_requirement(%{satisfied: false}),
            build_requirement(%{satisfied: true})
          ]
        })

      assert {2, 3} = StatusWriter.context_completion(context)
    end

    test "includes descendant requirements in counts" do
      child =
        build_component(%{
          name: "User",
          module_name: "MyApp.Accounts.User",
          type: "schema",
          requirements: [build_requirement(%{satisfied: true})]
        })

      context =
        build_component(%{
          name: "Accounts",
          module_name: "MyApp.Accounts",
          type: "context",
          child_components: [child],
          requirements: [build_requirement(%{satisfied: false})]
        })

      assert {1, 2} = StatusWriter.context_completion(context)
    end

    test "returns {0, 0} for context with no requirements" do
      context =
        build_component(%{
          name: "Accounts",
          module_name: "MyApp.Accounts",
          type: "context"
        })

      assert {0, 0} = StatusWriter.context_completion(context)
    end
  end

  describe "filter_tree/2" do
    test "removes matching children by name" do
      repo = build_component(%{name: "Repo", module_name: "MyApp.Repo"})
      accounts = build_component(%{name: "Accounts", module_name: "MyApp.Accounts"})

      app =
        build_component(%{
          name: "MyApp",
          module_name: "MyApp",
          child_components: [repo, accounts]
        })

      filtered = StatusWriter.filter_tree(app, ["Repo"])
      names = Enum.map(filtered.child_components, & &1.name)
      assert names == ["Accounts"]
    end

    test "recursively filters nested children" do
      repo = build_component(%{name: "Repo", module_name: "MyApp.Accounts.Repo"})
      user = build_component(%{name: "User", module_name: "MyApp.Accounts.User"})

      accounts =
        build_component(%{
          name: "Accounts",
          module_name: "MyApp.Accounts",
          child_components: [repo, user]
        })

      app =
        build_component(%{
          name: "MyApp",
          module_name: "MyApp",
          child_components: [accounts]
        })

      filtered = StatusWriter.filter_tree(app, ["Repo"])
      accounts_filtered = hd(filtered.child_components)
      names = Enum.map(accounts_filtered.child_components, & &1.name)
      assert names == ["User"]
    end

    test "returns component unchanged with empty ignore list" do
      app =
        build_component(%{
          name: "MyApp",
          module_name: "MyApp",
          child_components: [build_component(%{name: "Repo", module_name: "MyApp.Repo"})]
        })

      assert StatusWriter.filter_tree(app, []) == app
    end
  end
end
