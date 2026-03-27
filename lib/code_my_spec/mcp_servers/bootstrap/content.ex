defmodule CodeMySpec.McpServers.Bootstrap.Content do
  @moduledoc """
  Content generators for bootstrap installation files (CLAUDE.md, AGENTS.md).
  """

  @claude_md_start_marker "<!-- code_my_spec:start -->"
  @claude_md_end_marker "<!-- code_my_spec:end -->"

  def claude_md_start_marker, do: @claude_md_start_marker
  def claude_md_end_marker, do: @claude_md_end_marker

  @doc """
  Generate the managed CLAUDE.md section content for a project.
  Returns the content wrapped in marker comments for idempotent updates.
  """
  def claude_md_content(app_name) do
    app = app_name || "your_app"
    base = CodeMySpec.Paths.base_dir()

    """
    #{@claude_md_start_marker}
    ## CodeMySpec Project

    Read `#{base}/AGENTS.md` for the full project development guide.

    ### Key Conventions

    - All public context functions take `%Scope{}` as the first parameter
    - Contexts are the public API boundary — never call child modules directly
    - Use `use Boundary` in every module to enforce dependency rules
    - Check `#{base}/architecture/overview.md` for the component graph before adding dependencies

    ### Before Writing Code

    1. Check `#{base}/status/#{app}.md` for implementation status
    2. Read the spec in `#{base}/spec/` for the module you're working on
    3. Read the rules in `#{base}/rules/` for the component type (context, repository, schema, etc.)
    4. Check `#{base}/issues/` for known problems in the area
    #{@claude_md_end_marker}
    """
  end

  @doc """
  Generate the AGENTS.md content for a project.
  """
  def agents_md_content(app_name) do
    app = app_name || "your_app"
    base = CodeMySpec.Paths.base_dir()

    """
    # Project Development Guide

    This guide describes how the project's `#{base}/` directory works so you can locate what you need efficiently.

    ## Project Structure

    ```
    #{base}/
    ├── architecture/          ← System component graph and dependencies
    ├── status/                ← Implementation status of every component
    ├── spec/                  ← Specifications for every module
    ├── rules/                 ← Coding standards by component type
    ├── knowledge/             ← Project-specific operational knowledge
    ├── framework/             ← Framework reference (LiveView, DaisyUI, etc.)
    ├── tools/                 ← Helper scripts (set-story-component, etc.)
    ├── design/                ← Design system assets
    ├── issues/                ← Known bugs and technical debt
    └── qa/                    ← QA test results
    ```

    ## Progressive Disclosure: Where to Look

    ### 1. Orientation — What exists and how it's organized

    | Need | File |
    |---|---|
    | List of all components, types, and dependencies | `#{base}/architecture/overview.md` |
    | Hierarchical tree view by Elixir namespace | `#{base}/architecture/namespace_hierarchy.md` |
    | Dependency graph (Mermaid) | `#{base}/architecture/dependency_graph.mmd` |

    ### 2. Status — What's done and what's not

    | Need | File |
    |---|---|
    | Top-level status of all contexts | `#{base}/status/#{app}.md` |
    | Web layer status | `#{base}/status/#{app}_web.md` |
    | Status of a specific context | `#{base}/status/#{app}/<context_name>.md` |

    ### 3. Specifications — What a module should do

    | Need | File |
    |---|---|
    | Spec for a module | `#{base}/spec/<module_path>.spec.md` |

    Specs follow a standard format:
    - **Title**: Fully qualified module name with type
    - **Delegates**: Functions delegated to other modules
    - **Functions**: Public API with `@spec`, process steps, and test assertions
    - **Dependencies**: Required modules
    - **Fields**: (schemas only) Ecto field definitions

    ### 4. Rules — Coding standards for each component type

    | Component Type | Design Rules | Test Rules |
    |---|---|---|
    | Context | `#{base}/rules/context_design.md` | — |
    | Repository | `#{base}/rules/repository_design.md` | `#{base}/rules/repository_test.md` |
    | Schema | `#{base}/rules/schema_design.md` | — |
    | LiveView | `#{base}/rules/liveview_design.md` | — |
    | LiveView component | `#{base}/rules/liveview_component_design.md` | — |
    | Elixir (general) | `#{base}/rules/elixir_design.md` | `#{base}/rules/elixir_test.md` |

    ### 5. Design System — Visual reference

    | Need | File |
    |---|---|
    | Design system (colors, typography, components) | `#{base}/design/design_system.html` |

    ### 6. Issues — Known problems and technical debt

    Issues live in `#{base}/issues/` as individual markdown files.

    ### 7. Knowledge — Operational knowledge

    - `#{base}/knowledge/` — Project-specific research
    - `#{base}/framework/` — Framework knowledge (LiveView, DaisyUI, Boundary, etc.)

    ## Phoenix Contexts Architecture

    - **Contexts** are the public API boundary at `lib/#{app}/<context_name>.ex`
    - **Repositories** handle data access under the context namespace
    - **Schemas** define Ecto schemas under the context namespace
    - **Scope** is the first parameter to all public context functions

    ## Working with #{base}/

    **Before implementing a component:**
    1. Check `#{base}/status/` — is it already done?
    2. Read `#{base}/spec/` — what should it do?
    3. Read `#{base}/rules/` — what conventions apply?
    4. Check `#{base}/issues/` — are there known problems?
    """
  end

  @doc """
  Extract app name from a mix.exs file path.
  """
  def extract_app_name(mix_exs_path) do
    case File.read(mix_exs_path) do
      {:ok, content} ->
        case Regex.run(~r/app:\s*:(\w+)/, content) do
          [_, app_name] -> app_name
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
