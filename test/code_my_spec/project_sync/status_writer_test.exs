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
      accounts = build_component(%{name: "Accounts", module_name: "MyApp.Accounts", type: "context"})
      billing = build_component(%{name: "Billing", module_name: "MyApp.Billing", type: "context"})

      app = build_component(%{
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
      user = build_component(%{
        name: "User",
        module_name: "MyApp.Accounts.User",
        type: "schema"
      })

      accounts = build_component(%{
        name: "Accounts",
        module_name: "MyApp.Accounts",
        type: "context",
        child_components: [user]
      })

      app = build_component(%{
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

      accounts = build_component(%{
        name: "Accounts",
        module_name: "MyApp.Accounts",
        type: "context",
        child_components: [user]
      })

      app = build_component(%{
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
      req = build_requirement(%{name: "spec_file", description: "Specification file exists", satisfied: true})

      context = build_component(%{
        name: "Accounts",
        module_name: "MyApp.Accounts",
        type: "context",
        requirements: [req]
      })

      app = build_component(%{
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
      req = build_requirement(%{name: "test_file", description: "Test file exists", satisfied: false})

      context = build_component(%{
        name: "Accounts",
        module_name: "MyApp.Accounts",
        type: "context",
        requirements: [req]
      })

      app = build_component(%{
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

      context = build_component(%{
        name: "Accounts",
        module_name: "MyApp.Accounts",
        type: "context",
        requirements: reqs
      })

      app = build_component(%{
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
      context = build_component(%{
        name: "Accounts",
        module_name: "MyApp.Accounts",
        type: "context"
      })

      app = build_component(%{
        name: "MyApp",
        module_name: "MyApp",
        type: "module",
        child_components: [context]
      })

      StatusWriter.write_status_files([app], env)

      content = File.read!(Path.join(tmp_dir, "docs/status/my_app/accounts.md"))
      assert content =~ "_No requirements defined_"
    end

    test "overwrites existing status files without cleaning up unrelated files", %{tmp_dir: tmp_dir, env: env} do
      status_dir = Path.join(tmp_dir, "docs/status")
      File.mkdir_p!(status_dir)

      File.write!(Path.join(status_dir, "stale.md"), "stale")
      File.write!(Path.join(status_dir, ".gitkeep"), "")

      context = build_component(%{
        name: "Accounts",
        module_name: "MyApp.Accounts",
        type: "context"
      })

      app = build_component(%{
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
      context = build_component(%{
        name: "Accounts",
        module_name: "MyApp.Accounts",
        type: "context"
      })

      app = build_component(%{
        name: "MyApp",
        module_name: "MyApp",
        type: "module",
        child_components: [context]
      })

      StatusWriter.write_status_files([app], env)

      content = File.read!(Path.join(tmp_dir, "docs/status/my_app/accounts.md"))
      assert content =~ "## MyApp.Accounts (context)"
    end

    test "deep nesting renders all descendants inline in context file", %{tmp_dir: tmp_dir, env: env} do
      behaviour = build_component(%{
        name: "Behaviour",
        module_name: "MyApp.Integrations.Providers.Behaviour",
        type: "module"
      })

      providers = build_component(%{
        name: "Providers",
        module_name: "MyApp.Integrations.Providers",
        type: "module",
        child_components: [behaviour]
      })

      integrations = build_component(%{
        name: "Integrations",
        module_name: "MyApp.Integrations",
        type: "context",
        child_components: [providers]
      })

      app = build_component(%{
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
  end
end
