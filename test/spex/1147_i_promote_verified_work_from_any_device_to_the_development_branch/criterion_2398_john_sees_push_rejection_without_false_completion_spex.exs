defmodule CodeMySpecSpex.Story1147.Criterion2398Spex do
  @moduledoc "Story 1147: john sees push rejection without false completion."
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

  spex "John sees remote push rejection instead of a false landing", criterion: 2398 do
    scenario "origin rejects the candidate after it passes the gate" do
      given_ "a verified candidate and a remote policy rejecting publication", context do
        {:ok, context |> remote_project() |> verified_candidate() |> reject_push()}
      end

      when_ "John promotes his story", context do
        {:ok, context |> request_publication() |> outcome()}
      end

      then_ "the agent receives the rejection and origin is unchanged", context do
        assert context.outcome =~ "nothing of it landed"
        assert context.outcome =~ "policy-rejected"
        refute context.outcome =~ "published to origin/main"
        errors = SexySpex.ErrorCapture.get_errors()
        assert errors != []
        Enum.each(errors, fn error -> assert error.message =~ "policy-rejected" end)
        SexySpex.ErrorCapture.clear()
        assert remote_head(context) == context.base
        assert git!(context.origin, ["for-each-ref", "refs/codemyspec/promotions"]) == ""
        {:ok, context}
      end
    end
  end
end
