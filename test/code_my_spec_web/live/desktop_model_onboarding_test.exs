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

    assert has_element?(view, "[data-test=agent-installation-codex] a", "Use Codex")

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

      view
      |> element("[data-test=agent-installation-#{unquote(command)}] a[data-phx-link=patch]")
      |> render_click()

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

  test "hosted users can configure Claude before a local installation exists", %{
    conn: conn,
    scope: scope
  } do
    Application.put_env(:code_my_spec, :env, :test)
    {:ok, view, _} = live(log_in_user(conn, scope.user), "/app")

    assert has_element?(
             view,
             "[data-test=agent-installation-claude]",
             "Installation status is available in the desktop app"
           )

    view
    |> element("[data-test=agent-installation-claude] a[data-phx-link=patch]")
    |> render_click()

    assert has_element?(view, "[data-test=agent-models-form]")
    view |> form("[data-test=agent-models-form]") |> render_submit()
    assert_redirect(view, "/app")
    assert Agents.models_configured?(scope)
  end

  test "hosted Codex selection explains how to connect the provider", %{conn: conn, scope: scope} do
    Application.put_env(:code_my_spec, :env, :test)
    {:ok, view, _} = live(log_in_user(conn, scope.user), "/app?provider=openai-codex")

    assert has_element?(
             view,
             "[data-test=onboarding-models] a[href='/app/users/settings']",
             "Connect provider"
           )
  end

  test "rechecking installations preserves custom model edits", ctx do
    install(ctx.root, "claude")
    {:ok, view, _} = live(ctx.conn, "/app?provider=claude-code")
    render_async(view)

    view
    |> form("[data-test=agent-models-form]", %{
      "main" => %{"provider" => "claude-code", "model" => "custom-model"}
    })
    |> render_change()

    view |> element("button", "Check again") |> render_click()
    render_async(view)
    assert has_element?(view, "input[name='main[model]'][value='custom-model']")
  end

  test "the timeline advances through models, account and project", %{conn: conn, scope: scope} do
    Application.put_env(:code_my_spec, :env, :test)
    conn = log_in_user(conn, scope.user)
    {:ok, models, _} = live(conn, "/app?provider=claude-code")
    models |> form("[data-test=agent-models-form]") |> render_submit()
    assert_redirect(models, "/app")

    {:ok, account, _} = live(conn, "/app")
    assert has_element?(account, "[data-step=account][aria-current=step]")
    account |> form("#account_form", account: %{name: "My workspace"}) |> render_submit()
    assert_redirect(account, "/app")

    {:ok, project, _} = live(conn, "/app")
    assert has_element?(project, "[data-step=project][aria-current=step]")
    project |> form("#project_form", project: %{name: "First project"}) |> render_submit()
    assert_redirect(project, "/app")

    {:ok, finished, _} = live(conn, "/app")

    for step <- ["models", "account", "project"] do
      assert has_element?(finished, "[data-step=#{step}][data-state=done]")
    end

    refute has_element?(finished, "[aria-current=step]")
    refute has_element?(finished, "[data-test=model-onboarding]")
  end

  test "recheck sees an agent installed while the page is open", ctx do
    {:ok, view, _} = live(ctx.conn, "/app")
    render_async(view)
    install(ctx.root, "codex")
    view |> element("button", "Check again") |> render_click()
    render_async(view)
    assert has_element?(view, "[data-test=agent-installation-codex] a", "Use Codex")

    assert has_element?(
             view,
             "[data-test=agent-installation-claude]",
             "Not installed or unavailable"
           )
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
