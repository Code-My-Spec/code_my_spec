defmodule CodeMySpecWeb.AccountLive.AgentsDefaultsTest do
  @moduledoc """
  Saving one agent type does not pin the other three.

  Issue c6f5acce. The form posts all four types at once, and an untouched select
  rendered the *resolved default* as its value — so pressing Save wrote a row for
  every type, including three the person never touched. Reproduced live twice,
  once by a user who changed nothing at all and still ended up with four rows.

  `Agents.ModelSetting`'s own moduledoc argues against writing a default row at
  account creation, because it would freeze whatever the defaults were that day.
  Writing one on the first Save has exactly the same effect, and nothing
  distinguished the type somebody chose from the three that came along.

  The fix makes "use the default" a value the form can post — which also gives a
  pinned type a way back, something that did not exist at all before.
  """

  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeMySpec.IntegrationsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents

  setup %{conn: conn} do
    scope = full_scope_fixture()
    # A pinned type only resolves as pinned while its provider is connected, so
    # an account with no integration cannot express the state this is about.
    integration_fixture(scope.user, %{provider: :anthropic})
    %{conn: log_in_user(conn, scope.user), scope: scope}
  end

  defp pinned(scope) do
    scope
    |> Agents.model_settings()
    |> Enum.filter(&(&1.source != :default and &1.source != :none))
    |> Enum.map(& &1.role)
    |> Enum.sort()
  end

  test "clearing a type lets it resolve again", %{scope: scope} do
    assert {:ok, _} = Agents.put_model_setting(scope, :qa, "anthropic", "some-model")

    assert :qa in pinned(scope), "the premise is a type that has been pinned"

    assert :ok = Agents.clear_model_setting(scope, :qa)

    refute :qa in pinned(scope),
           "a pinned type had no way back to the defaults, which is the other half of " <>
             "the freeze: once written, the row outlives the reasoning that produced it."
  end

  test "clearing something never set is not an error", %{scope: scope} do
    assert :ok = Agents.clear_model_setting(scope, :product),
           "leave-it-as-the-default and it-already-was are the same instruction, " <>
             "and the form sends the first for every untouched row on every save."
  end

  test "the form offers the default as a choice", %{conn: conn, scope: scope} do
    {:ok, _live, html} = live(conn, ~p"/app/accounts/#{scope.active_account_id}/agents")

    assert html =~ "use-default",
           "there is no way to say 'leave this alone' in the payload, so an untouched " <>
             "select posts the default's own value and Save writes it down as a choice."
  end
end
