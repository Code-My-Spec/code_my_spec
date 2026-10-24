defmodule CodeMySpecSpex.Story1147.Criterion2399Spex do
  @moduledoc "Story 1147: johns lost push response is reconciled before retry."
  use CodeMySpecSpex.Case
  import CodeMySpecSpex.RemotePromotionHelpers
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "John's accepted publication survives a lost push response", criterion: 2399 do
    scenario "origin accepts the atomic push but the transport returns failure" do
      given_ "a verified candidate whose push response will be lost", context do
        {:ok, context |> remote_project() |> verified_candidate() |> lose_push_response()}
      end

      when_ "John promotes his story", context do
        {:ok, context |> request_publication() |> outcome()}
      end

      then_ "the queue reports the proven landing once with a single receipt", context do
        assert context.outcome =~ "published to origin/main"
        assert context.outcome =~ context.candidate
        assert remote_head(context) == context.candidate

        receipts =
          git!(context.origin, [
            "for-each-ref",
            "--format=%(objectname)",
            "refs/codemyspec/promotions"
          ])

        assert receipts == context.candidate
        refute context.outcome =~ "nothing of it landed"
        {:ok, context}
      end
    end
  end
end
