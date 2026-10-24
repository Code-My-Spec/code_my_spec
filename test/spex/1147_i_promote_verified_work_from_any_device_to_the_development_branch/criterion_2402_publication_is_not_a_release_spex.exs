defmodule CodeMySpecSpex.Story1147.Criterion2402Spex do
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

  spex "John publishes development work without advancing release branches", criterion: 2402 do
    scenario "John publishes development work without advancing release branches" do
      given_ "a candidate and separate UAT and production refs", context do
        context = context |> remote_project() |> verified_candidate()

        git!(context.agent_root, [
          "push",
          "origin",
          "#{context.base}:refs/heads/uat",
          "#{context.base}:refs/heads/production"
        ])

        {:ok, context}
      end

      when_ "John promotes development work", context do
        {:ok, context |> request_publication() |> outcome()}
      end

      then_ "only development advances", context do
        assert remote_head(context) == context.candidate
        assert git!(context.origin, ["rev-parse", "refs/heads/uat"]) == context.base
        assert git!(context.origin, ["rev-parse", "refs/heads/production"]) == context.base
        assert context.outcome =~ "published to origin/main"
        {:ok, context}
      end
    end
  end
end
