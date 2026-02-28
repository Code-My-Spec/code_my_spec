defmodule CodeMySpec.ProjectSetupWizard.ScriptGenerator do
  @moduledoc """
  Generates idempotent bash setup scripts for project initialization.

  Responsible for:
  - Creating executable bash scripts with git submodule commands
  - Generating Phoenix project creation commands
  - Handling missing repository URLs gracefully
  - Building idempotent script sections (checks before operations)
  """

  alias CodeMySpec.Projects.Project

  @doc """
  Generates idempotent bash setup script for project initialization.

  Creates executable script with:
  - Git repository validation
  - Git submodule commands for code and docs repositories
  - Phoenix project creation via mix phx.new
  - Git submodule initialization

  Handles missing repository URLs gracefully with placeholder comments.

  ## Parameters
  - `project` - Project with repository URLs

  ## Returns
  - `{:ok, String.t()}` - Executable bash script

  ## Examples

      iex> generate(project)
      {:ok, "#!/bin/bash\\nset -e\\n..."}

      iex> generate(project_without_repos)
      {:ok, "#!/bin/bash\\n# No repositories configured..."}
  """
  @spec generate(Project.t()) :: {:ok, String.t()}
  def generate(%Project{} = project) do
    script = build_setup_script(project)
    {:ok, script}
  end

  # ============================================================================
  # Private Helpers - Script Generation
  # ============================================================================

  defp build_setup_script(%Project{code_repo: nil, docs_repo: nil}) do
    """
    #!/bin/bash
    set -e

    echo "CodeMySpec Project Setup"
    echo "======================="
    echo ""
    echo "⚠️  No repositories configured yet."
    echo ""
    echo "Please configure your code and docs repositories in the web UI,"
    echo "then re-run this script to initialize your project structure."
    """
  end

  defp build_setup_script(%Project{} = project) do
    header = build_script_header()
    validation = build_validation_section()
    phx_new_check = build_phx_new_check_section()
    submodules = build_submodule_section(project)
    phoenix_project = build_phoenix_project_section(project)
    deps_update = build_deps_update_section()
    custom_deps = build_custom_deps_section()
    phx_gen_auth = build_phx_gen_auth_section(project)
    submodule_init = build_submodule_init_section()
    success = build_success_section()

    [
      header,
      validation,
      phx_new_check,
      submodules,
      phoenix_project,
      deps_update,
      custom_deps,
      phx_gen_auth,
      submodule_init,
      success
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp build_script_header do
    """
    #!/bin/bash
    set -e

    echo "CodeMySpec Project Setup"
    echo "======================="
    echo ""
    """
  end

  defp build_validation_section do
    """
    # Validate we're in a git repository
    if [ ! -d .git ]; then
      echo "❌ Error: Not in a git repository"
      echo "Please run this script from the root of your git repository"
      exit 1
    fi

    echo "✓ Git repository detected"
    """
  end

  defp build_phx_new_check_section do
    """
    # Check if phx.new is installed
    if ! mix archive | grep -q "phx_new"; then
      echo "Installing Phoenix project generator..."
      mix archive.install hex phx_new --force
      echo "✓ Phoenix generator installed"
    else
      echo "✓ Phoenix generator already installed"
    fi
    """
  end

  defp build_submodule_section(%Project{code_repo: nil, docs_repo: nil}), do: nil

  defp build_submodule_section(%Project{code_repo: _code_repo, docs_repo: docs_repo}) do
    docs_section = build_docs_submodule(docs_repo)

    [docs_section]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp build_docs_submodule(nil), do: nil

  defp build_docs_submodule(docs_repo) do
    """
    # Add docs repository submodule (if not already added)
    if [ ! -d ".code_my_spec/.git" ] && [ ! -f ".code_my_spec/.git" ]; then
      echo "Adding docs repository submodule..."
      git submodule add #{docs_repo} .code_my_spec
      echo "✓ Docs submodule added"
    else
      echo "✓ Docs submodule already exists"
    fi
    """
  end

  defp build_phoenix_project_section(%Project{module_name: module_name})
       when not is_nil(module_name) do
    """
    # Create Phoenix project (if not already created)
    if [ ! -f "mix.exs" ]; then
      echo "Creating Phoenix project..."
      mix phx.new . --app #{Macro.underscore(module_name)} --no-install
      echo "✓ Phoenix project created"
    else
      echo "✓ Phoenix project already exists"
    fi
    """
  end

  defp build_phoenix_project_section(%Project{name: name}) do
    app_name = name |> String.downcase() |> String.replace(~r/[^a-z0-9_]/, "_")

    """
    # Create Phoenix project (if not already created)
    if [ ! -f "mix.exs" ]; then
      echo "Creating Phoenix project..."
      mix phx.new . --app #{app_name} --no-install
      echo "✓ Phoenix project created"
    else
      echo "✓ Phoenix project already exists"
    fi
    """
  end

  defp build_deps_update_section do
    """
    # Get dependencies
    echo "Getting dependencies..."
    mix deps.get
    echo "✓ Dependencies installed"
    """
  end

  defp build_custom_deps_section do
    """
    # Custom dependencies to add to mix.exs
    echo ""
    echo "📦 Add these custom dependencies to your mix.exs file:"
    echo ""
    echo '  {:ngrok, git: "https://github.com/johns10/ex_ngrok", branch: "main", only: [:dev]},'
    echo '  {:exunit_json_formatter, git: "https://github.com/johns10/exunit_json_formatter", branch: "master"},'
    echo '  {:credo, "~> 1.7.13"},'
    echo ""
    echo "After adding, run: mix deps.get"
    """
  end

  defp build_phx_gen_auth_section(%Project{module_name: module_name})
       when not is_nil(module_name) do
    """
    # Generate authentication with phx.gen.auth
    if ! grep -q "#{module_name}.Accounts" lib/*/accounts.ex 2>/dev/null; then
      echo "Generating authentication system..."
      mix phx.gen.auth Accounts User users
      echo "✓ Authentication system generated"
    else
      echo "✓ Authentication system already exists"
    fi
    """
  end

  defp build_phx_gen_auth_section(%Project{name: name}) do
    module_name = name |> Macro.camelize()

    """
    # Generate authentication with phx.gen.auth
    if ! grep -q "#{module_name}.Accounts" lib/*/accounts.ex 2>/dev/null; then
      echo "Generating authentication system..."
      mix phx.gen.auth Accounts User users
      echo "✓ Authentication system generated"
    else
      echo "✓ Authentication system already exists"
    fi
    """
  end

  defp build_submodule_init_section do
    """
    # Initialize and update submodules
    if [ -f ".gitmodules" ]; then
      echo "Initializing submodules..."
      git submodule update --init --recursive
      echo "✓ Submodules initialized"
    fi
    """
  end

  defp build_success_section do
    """
    echo ""
    echo "✅ Setup complete!"
    echo ""
    echo "Next steps:"
    echo "1. Install dependencies: mix deps.get"
    echo "2. Review the directory structure"
    echo "3. Start defining your components and tests"
    echo "4. Run mix ecto.create to create your database"
    """
  end
end
