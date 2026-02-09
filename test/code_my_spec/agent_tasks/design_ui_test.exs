defmodule CodeMySpec.AgentTasks.DesignUiTest do
  @moduledoc false
  use CodeMySpec.DataCase

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.DesignUi
  alias CodeMySpec.Environments.Environment

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp create_scope(_context) do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    scope = %{scope | environment: Environment.new(:local, tmp_dir)}
    %{scope: scope, tmp_dir: tmp_dir}
  end

  defp create_session(context) do
    %{scope: scope} = context
    session = %{project: scope.active_project}
    Map.put(context, :session, session)
  end

  defp write_file!(env, relative_path, content) do
    full_path = Path.join(env.cwd, relative_path)
    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(full_path, content)
  end

  defp write_design_system_html(env, content \\ nil) do
    write_file!(env, "docs/design/design_system.html", content || valid_design_system_html())
  end

  defp write_template_file(env) do
    write_file!(env, "priv/templates/design_system.html", template_html())
  end

  defp write_tailwind_config(env) do
    write_file!(env, "assets/tailwind.config.js", """
    module.exports = {
      plugins: [require("daisyui")],
      daisyui: { themes: ["corporate"] },
    }
    """)
  end

  defp write_core_components(env) do
    write_file!(env, "lib/my_app_web/components/core_components.ex", """
    defmodule MyAppWeb.CoreComponents do
      use Phoenix.Component
      def button(assigns), do: ~H|<button class="btn"><%= render_slot(@inner_block) %></button>|
      def modal(assigns), do: ~H|<div class="modal"><%= render_slot(@inner_block) %></div>|
    end
    """)
  end

  defp valid_design_system_html do
    """
    <!DOCTYPE html>
    <html data-theme="corporate">
    <head><title>Design System</title></head>
    <body>
      <section id="theme"><h2>Theme</h2><p>Corporate theme selected</p></section>
      <section id="colors"><h2>Colors</h2><p>Primary: blue, Secondary: gray</p></section>
      <section id="typography"><h2>Typography</h2><p>Inter font, 1.25 scale</p></section>
      <section id="layout"><h2>Layout</h2><p>Sidebar navigation, max-w-7xl</p></section>
      <section id="tone"><h2>Tone</h2><p>Minimal, rounded-lg, subtle shadows</p></section>
    </body>
    </html>
    """
  end

  defp template_html do
    """
    <!DOCTYPE html>
    <html data-theme="">
    <head><title>Design System Template</title></head>
    <body>
      <section id="theme"><h2>Theme</h2></section>
      <section id="colors"><h2>Colors</h2></section>
      <section id="typography"><h2>Typography</h2></section>
      <section id="layout"><h2>Layout</h2></section>
      <section id="tone"><h2>Tone</h2></section>
    </body>
    </html>
    """
  end

  defp html_missing_sections do
    """
    <!DOCTYPE html>
    <html data-theme="corporate">
    <head><title>Design System</title></head>
    <body>
      <section id="theme"><h2>Theme</h2><p>Corporate theme</p></section>
      <section id="colors"><h2>Colors</h2><p>Primary: blue</p></section>
    </body>
    </html>
    """
  end

  defp html_no_data_theme do
    """
    <!DOCTYPE html>
    <html>
    <head><title>Design System</title></head>
    <body>
      <section id="theme"><h2>Theme</h2><p>Corporate theme</p></section>
      <section id="colors"><h2>Colors</h2><p>Primary: blue</p></section>
      <section id="typography"><h2>Typography</h2><p>Inter font</p></section>
      <section id="layout"><h2>Layout</h2><p>Sidebar nav</p></section>
      <section id="tone"><h2>Tone</h2><p>Minimal</p></section>
    </body>
    </html>
    """
  end

  defp html_empty_section do
    """
    <!DOCTYPE html>
    <html data-theme="corporate">
    <head><title>Design System</title></head>
    <body>
      <section id="theme"><h2>Theme</h2><p>Corporate theme</p></section>
      <section id="colors"><h2>Colors</h2><p>Primary: blue</p></section>
      <section id="typography"><h2>Typography</h2></section>
      <section id="layout"><h2>Layout</h2><p>Sidebar nav</p></section>
      <section id="tone"><h2>Tone</h2><p>Minimal</p></section>
    </body>
    </html>
    """
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    setup [:create_scope, :create_session]

    test "returns ok tuple with prompt text", %{scope: scope, session: session} do
      write_template_file(scope.environment)

      assert {:ok, prompt} = DesignUi.command(scope, session)
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "loads template from priv/templates/design_system.html for new projects", %{
      scope: scope,
      session: session
    } do
      write_template_file(scope.environment)

      assert {:ok, prompt} = DesignUi.command(scope, session)
      assert prompt =~ "Design System Template"
    end

    test "includes existing design system content when file already exists", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_template_file(env)
      write_design_system_html(env)

      assert {:ok, prompt} = DesignUi.command(scope, session)
      assert prompt =~ "Corporate theme selected"
    end

    test "includes tailwind config when available", %{scope: scope, session: session} do
      env = scope.environment
      write_template_file(env)
      write_tailwind_config(env)

      assert {:ok, prompt} = DesignUi.command(scope, session)
      assert prompt =~ "tailwind" or prompt =~ "daisyui" or prompt =~ "brand"
    end

    test "includes core_components reference", %{scope: scope, session: session} do
      env = scope.environment
      write_template_file(env)
      write_core_components(env)

      assert {:ok, prompt} = DesignUi.command(scope, session)
      assert prompt =~ "core_components" or prompt =~ "CoreComponents" or prompt =~ "button" or
               prompt =~ "modal"
    end

    test "prompt includes the template or existing file content", %{
      scope: scope,
      session: session
    } do
      write_template_file(scope.environment)

      assert {:ok, prompt} = DesignUi.command(scope, session)
      assert prompt =~ "<html" or prompt =~ "<!DOCTYPE" or prompt =~ "section"
    end

    test "prompt instructs agent to interview user section by section", %{
      scope: scope,
      session: session
    } do
      write_template_file(scope.environment)

      assert {:ok, prompt} = DesignUi.command(scope, session)

      assert prompt =~ "theme" or prompt =~ "Theme"
      assert prompt =~ "color" or prompt =~ "Color"
      assert prompt =~ "typography" or prompt =~ "Typography"
      assert prompt =~ "layout" or prompt =~ "Layout"
      assert prompt =~ "tone" or prompt =~ "Tone"
    end

    test "prompt instructs agent to present DaisyUI theme options", %{
      scope: scope,
      session: session
    } do
      write_template_file(scope.environment)

      assert {:ok, prompt} = DesignUi.command(scope, session)
      assert prompt =~ "DaisyUI" or prompt =~ "daisyui" or prompt =~ "daisy"
    end

    test "prompt instructs agent to modify template rather than generate from scratch", %{
      scope: scope,
      session: session
    } do
      write_template_file(scope.environment)

      assert {:ok, prompt} = DesignUi.command(scope, session)
      assert prompt =~ "modify" or prompt =~ "template" or prompt =~ "update"
    end

    test "includes project name and description for context", %{scope: scope, session: session} do
      write_template_file(scope.environment)

      assert {:ok, prompt} = DesignUi.command(scope, session)
      assert prompt =~ scope.active_project.name
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_session]

    test "returns {:ok, :valid} when HTML has all required sections and theme", %{
      scope: scope,
      session: session
    } do
      write_design_system_html(scope.environment)

      assert {:ok, :valid} = DesignUi.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when sections are missing", %{
      scope: scope,
      session: session
    } do
      write_design_system_html(scope.environment, html_missing_sections())

      assert {:ok, :invalid, feedback} = DesignUi.evaluate(scope, session)
      assert is_binary(feedback)
      assert feedback =~ "typography" or feedback =~ "layout" or feedback =~ "tone"
    end

    test "returns {:ok, :invalid, feedback} when data-theme is not set", %{
      scope: scope,
      session: session
    } do
      write_design_system_html(scope.environment, html_no_data_theme())

      assert {:ok, :invalid, feedback} = DesignUi.evaluate(scope, session)
      assert is_binary(feedback)
      assert feedback =~ "theme" or feedback =~ "data-theme"
    end

    test "returns {:ok, :invalid, feedback} when a section is empty", %{
      scope: scope,
      session: session
    } do
      write_design_system_html(scope.environment, html_empty_section())

      assert {:ok, :invalid, feedback} = DesignUi.evaluate(scope, session)
      assert is_binary(feedback)
      assert feedback =~ "typography" or feedback =~ "empty" or feedback =~ "content"
    end

    test "returns error when file does not exist", %{scope: scope, session: session} do
      result = DesignUi.evaluate(scope, session)

      assert {:error, _reason} = result
    end

    test "returns error when file cannot be parsed as HTML", %{scope: scope, session: session} do
      write_file!(scope.environment, "docs/design/design_system.html", "")

      result = DesignUi.evaluate(scope, session)

      assert match?({:error, _}, result) or match?({:ok, :invalid, _}, result)
    end
  end
end
