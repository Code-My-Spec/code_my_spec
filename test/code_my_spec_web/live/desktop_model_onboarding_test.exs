defmodule CodeMySpecWeb.DesktopModelOnboardingTest do
  use CodeMySpecTest.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias CodeMySpec.Agents
  alias CodeMySpec.UserPreferences
  alias CodeMySpec.UserPreferences.DesktopUser

  setup do
    previous_env = Application.fetch_env(:code_my_spec, :env)
    previous_path = System.get_env("PATH")
    root = Path.join(System.tmp_dir!(), "model-onboarding-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:code_my_spec, :env, :desktop)
    System.put_env("PATH", root)
    user = CodeMySpec.UsersFixtures.user_fixture(%{email: DesktopUser.email()})
    scope = UserPreferences.scope_for(user)

    on_exit(fn ->
      case previous_env do
        {:ok, env} -> Application.put_env(:code_my_spec, :env, env)
        :error -> Application.delete_env(:code_my_spec, :env)
      end

      System.put_env("PATH", previous_path)
      File.rm_rf!(root)
    end)

    %{root: root, scope: scope}
  end

  defp install(root, command) do
    path = Path.join(root, command)
    File.write!(path, "#!/bin/sh\nprintf '%s\\n' '#{command} 1.0'\n")
    File.chmod!(path, 0o700)
  end

  test "fresh desktop opens model selection without development setup", %{conn: conn} do
    {:ok, view, _} = live(conn, "/app")
    render_async(view)
    assert has_element?(view, "[data-test=model-onboarding]")
    assert has_element?(view, "[data-test=agent-installation-codex] a", "Install Codex")
    assert has_element?(view, "[data-test=agent-installation-claude] a", "Install Claude Code")

    assert has_element?(
             view,
             "[data-test=agent-installation-codex] button[disabled]",
             "Use Codex"
           )

    assert has_element?(view, "[data-test=account-rung][data-state=pending]")
    assert has_element?(view, "[data-test=project-rung][data-state=pending]")
    assert has_element?(view, "[data-step=models][aria-current=step]")
    assert has_element?(view, "[data-test=ladder-progress-count]", "/ 3 complete")
    refute render(view) =~ "Set up this machine"
    refute render(view) =~ "pgvector"
  end

  for {command, provider} <- [{"codex", "openai-codex"}, {"claude", "claude-code"}] do
    test "#{command} preselects models, saves per user and completes onboarding", ctx do
      install(ctx.root, unquote(command))
      {:ok, view, _} = live(ctx.conn, "/app")
      render_async(view)
      view |> element("[data-test=agent-installation-#{unquote(command)}] a") |> render_click()
      assert_patch(view, "/app?provider=#{unquote(provider)}")

      for role <- Agents.roles() do
        assert has_element?(
                 view,
                 "select[name='#{role}[provider]'] option[selected][value='#{unquote(provider)}']"
               )

        assert has_element?(
                 view,
                 "input[name='#{role}[model]'][value='#{Agents.default_model(role, unquote(provider))}']"
               )
      end

      view |> form("[data-test=agent-models-form]") |> render_submit()
      assert_redirect(view, "/app")
      assert Agents.models_configured?(ctx.scope)

      assert Enum.all?(
               Agents.model_settings(ctx.scope),
               &(&1.provider == unquote(provider) and &1.source == :set)
             )

      other = CodeMySpec.UsersFixtures.user_fixture() |> UserPreferences.scope_for()
      refute Agents.models_configured?(other)
      {:ok, returning, _} = live(ctx.conn, "/app")
      refute has_element?(returning, "[data-test=model-onboarding]")
      assert has_element?(returning, "#onboarding-page")
      assert has_element?(returning, "[data-step=models][data-state=done]")
      assert has_element?(returning, "[data-step=account][aria-current=step]")
      assert has_element?(returning, "[data-test=models-rung][data-state=done]")
    end
  end

  test "hosted users also start with model selection", %{conn: conn, scope: scope} do
    Application.put_env(:code_my_spec, :env, :test)
    {:ok, view, _} = live(log_in_user(conn, scope.user), "/app")
    render_async(view)
    assert has_element?(view, "[data-step=models][aria-current=step]")
    assert has_element?(view, "[data-test=model-onboarding]")
    refute has_element?(view, "#account_form")
    refute has_element?(view, "#project_form")
  end

  test "recheck sees an agent installed while the page is open", ctx do
    {:ok, view, _} = live(ctx.conn, "/app")
    render_async(view)
    install(ctx.root, "codex")
    view |> element("button", "Check again") |> render_click()
    render_async(view)
    assert has_element?(view, "[data-test=agent-installation-codex] a", "Use Codex")
    refute has_element?(view, "[data-test=agent-installation-claude] a", "Use Claude Code")
  end

  test "failed model save does not partially overwrite settings", %{scope: scope} do
    {:ok, _} = Agents.put_model_setting(scope, :main, "claude-code", "sonnet")

    params = %{
      "main" => %{"provider" => "openai-codex", "model" => "custom"},
      "qa" => %{"provider" => "unknown", "model" => "custom"}
    }

    assert {:error, :unknown_provider} = Agents.save_model_settings(scope, params)
    assert {:ok, {"claude-code", "sonnet"}, :set} = Agents.resolve_model(scope, :main)
  end
end
