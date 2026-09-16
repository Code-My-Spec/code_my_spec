defmodule CodeMySpecSpex.Story1040.Criterion3026Spex do
  @moduledoc """
  Story 1040 — I connect a model provider by pasting its API key
  Criterion 3026 — Two people on one account run QA on different models

  The scope decision, stated as something observable. Story 1039 stored the
  model setting against the account while the credential it resolves against is
  keyed by user, so an account-level "QA runs on Z.ai" was true for whoever
  pasted the key and a lie for everybody else on the account.

  Both halves now sit on the person. The contractor shares Sam's account and
  reads their own answer — which is the difference this criterion measures,
  and the reason both users are on one account rather than two.
  """

  use CodeMySpecSpex.Case

  cloud_endpoint()

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account

  spex "I connect a model provider by pasting its API key" do
    scenario "Two people on one account run QA on different models" do
      given_ "Sam has Z.ai connected and QA pointed at it", context do
        Fixtures.connect_provider(context.scope, "zai")

        {:ok, view, _html} = live(context.conn, ~p"/app/accounts/#{context.account.id}/agents")

        view
        |> form("[data-test='agent-models-form']", %{
          "qa" => %{"provider" => "zai", "model" => "glm-cheap"}
        })
        |> render_submit()

        {:ok, context}
      end

      given_ "a contractor on the same account has ChatGPT and nothing else", context do
        contractor = Fixtures.user_fixture()
        Fixtures.member_fixture(contractor, context.account)

        contractor_scope = Fixtures.user_scope_fixture(contractor, context.account)
        Fixtures.select_active_account(contractor_scope, context.account.id)
        Fixtures.connect_provider(contractor_scope, "openai")

        {:ok,
         Map.put(context, :contractor_conn, log_in_user(build_conn(), contractor))}
      end

      when_ "the contractor opens the agent models page", context do
        {:ok, view, _html} =
          live(context.contractor_conn, ~p"/app/accounts/#{context.account.id}/agents")

        {:ok, Map.put(context, :contractor_view, view)}
      end

      then_ "QA there is the contractor's own answer, not Sam's", context do
        rendered = context.contractor_view |> element("[data-test='agent-type-qa']") |> render()

        refute rendered =~ "glm-cheap",
               "an account-scoped setting hands one person's choice to everybody on the account"

        assert rendered =~ "default",
               "the contractor set nothing, so their QA type should read as a default"

        {:ok, context}
      end

      then_ "and Sam's own choice is unchanged", context do
        {:ok, view, _html} = live(context.conn, ~p"/app/accounts/#{context.account.id}/agents")

        assert view |> element("[data-test='agent-type-qa']") |> render() =~ "glm-cheap"

        {:ok, context}
      end
    end
  end
end
