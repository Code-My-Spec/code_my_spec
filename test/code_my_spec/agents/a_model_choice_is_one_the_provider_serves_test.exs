defmodule CodeMySpec.Agents.AModelChoiceIsOneTheProviderServesTest do
  @moduledoc """
  Model choices come from what a provider serves, not free text. The coding
  default was pinned to gpt-6.1-sol after the Codex login stopped serving it,
  and every Codex coder crash-looped. A harness reports what each local login
  serves at join; a default the provider does not serve resolves to the login's
  own default, a setting it does not serve is refused, and a provider with no
  list reported is allowed and said to be unverified.
  """
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CmsHarness.Agents.Provider
  alias CodeMySpec.Agents
  alias CodeMySpec.Analysis.HarnessRegistry

  @moduletag :tmp_dir

  setup %{conn: conn} do
    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    # The settings page is per user; its scope's account is the user's active one.
    {:ok, _} =
      CodeMySpec.UserPreferences.create_user_preferences(scope, %{
        active_account_id: scope.active_account_id
      })

    %{conn: log_in_user(conn, scope.user), scope: scope, copy: copy}
  end

  # What the channel does with a join's `served_models`.
  defp reported(copy, models), do: HarnessRegistry.register_served_models(copy.id, models)

  test "a default the provider does not serve resolves to the login's default", ctx do
    reported(ctx.copy, %{"claude-code" => ["claude-opus-5-5"]})

    assert {:ok, {"claude-code", nil}, :default} = Agents.resolve_model(ctx.scope, :coding)
  end

  test "a default the provider serves, or one with no list, stays", ctx do
    assert {:ok, {"claude-code", "claude-sonnet-5"}, :default} =
             Agents.resolve_model(ctx.scope, :coding)

    reported(ctx.copy, %{"claude-code" => ["claude-sonnet-5"]})

    assert {:ok, {"claude-code", "claude-sonnet-5"}, :default} =
             Agents.resolve_model(ctx.scope, :coding)
  end

  test "a setting the provider does not serve is refused, naming what it serves", ctx do
    reported(ctx.copy, %{"claude-code" => ["claude-opus-5-5", "claude-sonnet-5"]})

    assert {:error, {:model_not_served, ["claude-opus-5-5", "claude-sonnet-5"]}} =
             Agents.put_model_setting(ctx.scope, :qa, "claude-code", "gpt-6.1-sol")

    assert {:ok, _} = Agents.put_model_setting(ctx.scope, :qa, "claude-code", "claude-opus-5-5")
  end

  test "with no list reported, any model is allowed", ctx do
    assert {:ok, _} = Agents.put_model_setting(ctx.scope, :qa, "claude-code", "anything-at-all")
  end

  test "the settings form offers served models, or says the list is unverified", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/app/agent-models")
    assert has_element?(view, "[data-test='unverified-coding']")

    reported(ctx.copy, %{"claude-code" => ["claude-opus-5-5", "claude-sonnet-5"]})
    {:ok, view, _html} = live(ctx.conn, ~p"/app/agent-models")

    assert has_element?(
             view,
             "[data-test='served-models-coding'] option[value='claude-sonnet-5']"
           )

    refute has_element?(view, "[data-test='unverified-coding']")
  end

  test "the harness reports Codex's cached models, and unknown where nothing lists them",
       %{tmp_dir: home} do
    assert %{"openai-codex" => "unknown", "claude-code" => "unknown"} =
             Provider.served_models(home)

    File.write!(
      Path.join(home, "models_cache.json"),
      Jason.encode!(%{"models" => [%{"slug" => "gpt-6-sol"}, %{"slug" => "gpt-6-luna"}]})
    )

    assert %{"openai-codex" => ["gpt-6-sol", "gpt-6-luna"]} = Provider.served_models(home)
  end
end
