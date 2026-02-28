defmodule CodeMySpec.AgentTasks.DesignUi do
  @moduledoc """
  Agent task that interviews the user to establish the project's design system.

  Produces a self-contained HTML file (`.code_my_spec/design/design_system.html`) that serves as
  both documentation and live preview using DaisyUI CDN with a theme switcher. The agent
  walks the user through theme selection, color palette, typography scale, layout patterns,
  and tone, modifying an HTML template as they go.
  """

  alias CodeMySpec.Environments

  @design_system_path CodeMySpec.Paths.design_system_path()
  @template_path "priv/templates/design_system.html"
  @tailwind_config_path "assets/tailwind.config.js"
  @required_sections ~w(theme colors typography layout tone)

  @spec command(term(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def command(scope, _session, _opts \\ []) do
    env = scope.environment
    project = scope.active_project

    html_content = load_html_content(env)
    tailwind_config = read_optional_file(env, @tailwind_config_path)
    core_components = find_core_components(env)

    prompt = build_prompt(project, html_content, tailwind_config, core_components)
    {:ok, prompt}
  end

  @spec evaluate(term(), map(), keyword()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()} | {:error, term()}
  def evaluate(scope, _session, _opts \\ []) do
    env = scope.environment

    with {:ok, content} <- Environments.read_file(env, @design_system_path),
         {:ok, html} <- parse_html(content) do
      validate_html(html)
    end
  end

  # ============================================================================
  # HTML Content Loading
  # ============================================================================

  defp load_html_content(env) do
    if Environments.file_exists?(env, @design_system_path) do
      case Environments.read_file(env, @design_system_path) do
        {:ok, content} -> {:existing, content}
        _ -> load_template(env)
      end
    else
      load_template(env)
    end
  end

  defp load_template(env) do
    case Environments.read_file(env, @template_path) do
      {:ok, content} -> {:template, content}
      _ -> {:template, default_template()}
    end
  end

  defp read_optional_file(env, path) do
    case Environments.read_file(env, path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp find_core_components(env) do
    matches = Environments.glob(env, "lib/**/*core_components*")

    case matches do
      [first | _] -> read_optional_file(env, first)
      [] -> nil
    end
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt(project, html_content, tailwind_config, core_components) do
    sections = [
      build_project_context(project),
      build_html_section(html_content),
      build_tailwind_section(tailwind_config),
      build_core_components_section(core_components),
      build_instructions()
    ]

    Enum.reject(sections, &is_nil/1)
    |> Enum.join("\n\n")
  end

  defp build_project_context(project) do
    description =
      if project.description,
        do: "\nDescription: #{project.description}",
        else: ""

    """
    # Design System Setup

    Project: #{project.name}#{description}

    You are helping the user establish a design system for their project. The output is a
    self-contained HTML file at `.code_my_spec/design/design_system.html` that uses the DaisyUI CDN
    with a theme switcher so colors, typography, and components render in the actual theme.
    """
  end

  defp build_html_section({:existing, content}) do
    """
    ## Current Design System

    The project already has a design system file. Review the current content and walk the user
    through revisions rather than starting fresh.

    ```html
    #{content}
    ```
    """
  end

  defp build_html_section({:template, content}) do
    """
    ## Design System Template

    This is a new project. Start with the template below and modify it based on the user's choices.
    Do NOT generate HTML from scratch — modify this template.

    ```html
    #{content}
    ```
    """
  end

  defp build_tailwind_section(nil), do: nil

  defp build_tailwind_section(content) do
    """
    ## Existing Tailwind Configuration

    The project has an existing tailwind config. Consider these settings when making design decisions:

    ```javascript
    #{content}
    ```
    """
  end

  defp build_core_components_section(nil), do: nil

  defp build_core_components_section(content) do
    """
    ## Core Components Reference

    The project has these core_components available. The design system should complement them:

    ```elixir
    #{content}
    ```
    """
  end

  defp build_instructions do
    """
    ## Interview Instructions

    Walk the user through each section one at a time. At each step, show concrete options and
    examples — don't ask open-ended questions. Modify the template based on their choices.

    ### 1. Theme
    Present DaisyUI built-in themes by name: corporate, nord, dracula, winter, cupcake, emerald,
    cyberpunk, valentine, garden, lofi, pastel, wireframe, luxury, night, coffee, dim, sunset.
    Ask the user to pick a base theme or go custom. If custom, you'll define CSS variables using
    the `[data-theme="my-brand"]` format with oklch color values.

    ### 2. Colors
    If custom theme: walk through primary, secondary, accent, and neutral color roles with oklch values.
    If built-in theme: confirm the palette works or adjust individual colors.
    Show color swatches in the HTML as you go.

    ### 3. Typography
    Ask about heading scale, content density, and font preferences.
    Options: compact (1.125 scale), default (1.25 scale), spacious (1.333 scale).
    Font options: system fonts, Inter, or custom.

    ### 4. Layout
    Ask about navigation pattern (sidebar, top nav, hybrid), content width (narrow/medium/wide),
    and page templates needed (list, form, detail, dashboard).

    ### 5. Tone
    Ask about visual personality:
    - Density: minimal vs information-dense
    - Corners: rounded-lg vs rounded-sm vs sharp
    - Shadows: none, subtle, pronounced
    - Overall feel: professional, playful, technical

    After each section, update the HTML template file with the user's choices. Write the file
    to `.code_my_spec/design/design_system.html`.
    """
  end

  # ============================================================================
  # HTML Validation
  # ============================================================================

  defp parse_html(""), do: {:error, :empty_content}

  defp parse_html(content) do
    case Floki.parse_document(content) do
      {:ok, tree} -> {:ok, tree}
      {:error, reason} -> {:error, {:parse_error, reason}}
    end
  end

  defp validate_html(tree) do
    issues = []

    issues = check_data_theme(tree, issues)
    issues = check_required_sections(tree, issues)
    issues = check_section_content(tree, issues)

    case issues do
      [] -> {:ok, :valid}
      issues -> {:ok, :invalid, format_issues(issues)}
    end
  end

  defp check_data_theme(tree, issues) do
    case Floki.find(tree, "html[data-theme]") do
      [] ->
        [{:missing_theme, "No data-theme attribute set on <html> element"} | issues]

      elements ->
        case Floki.attribute(elements, "data-theme") do
          ["" | _] ->
            [{:empty_theme, "data-theme attribute is empty"} | issues]

          [_value | _] ->
            issues

          _ ->
            [{:missing_theme, "No data-theme attribute set on <html> element"} | issues]
        end
    end
  end

  defp check_required_sections(tree, issues) do
    Enum.reduce(@required_sections, issues, fn section_id, acc ->
      case Floki.find(tree, "section##{section_id}") do
        [] -> [{:missing_section, "Missing required section: #{section_id}"} | acc]
        _ -> acc
      end
    end)
  end

  defp check_section_content(tree, issues) do
    Enum.reduce(@required_sections, issues, fn section_id, acc ->
      case Floki.find(tree, "section##{section_id}") do
        [section | _] -> check_single_section_content(section, section_id, acc)
        [] -> acc
      end
    end)
  end

  defp check_single_section_content(section, section_id, acc) do
    text = Floki.text(section) |> String.trim()

    heading_text =
      section
      |> Floki.find("h1, h2, h3, h4, h5, h6")
      |> Enum.map_join("", &(&1 |> Floki.text() |> String.trim()))

    content_text = String.replace(text, heading_text, "") |> String.trim()

    if content_text == "" do
      [{:empty_section, "Section '#{section_id}' has no content beyond its heading"} | acc]
    else
      acc
    end
  end

  defp format_issues(issues) do
    issues
    |> Enum.reverse()
    |> Enum.map_join("\n", fn {_type, message} -> "- #{message}" end)
  end

  # ============================================================================
  # Default Template
  # ============================================================================

  defp default_template do
    """
    <!DOCTYPE html>
    <html data-theme="">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Design System Template</title>
      <link href="https://cdn.jsdelivr.net/npm/daisyui@4/dist/full.min.css" rel="stylesheet">
      <script src="https://cdn.tailwindcss.com"></script>
    </head>
    <body class="p-8">
      <h1 class="text-3xl font-bold mb-8">Design System</h1>

      <section id="theme">
        <h2 class="text-2xl font-semibold mb-4">Theme</h2>
      </section>

      <section id="colors">
        <h2 class="text-2xl font-semibold mb-4">Colors</h2>
      </section>

      <section id="typography">
        <h2 class="text-2xl font-semibold mb-4">Typography</h2>
      </section>

      <section id="layout">
        <h2 class="text-2xl font-semibold mb-4">Layout</h2>
      </section>

      <section id="tone">
        <h2 class="text-2xl font-semibold mb-4">Tone</h2>
      </section>
    </body>
    </html>
    """
  end
end
