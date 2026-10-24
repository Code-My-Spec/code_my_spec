defmodule CodeMySpecSpex.Story1147.Criterion2388Spex do
  @moduledoc "Story 1147: john promotes to main by default and can later choose dev."
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

  spex "John publishes to the configured development branch", criterion: 2388 do
    scenario "main is the default destination" do
      given_ "a verified candidate and origin with main", context do
        {:ok, context |> remote_project() |> verified_candidate()}
      end

      when_ "John promotes his story", context do
        {:ok, context |> request_publication() |> outcome()}
      end

      then_ "origin main receives the candidate", context do
        assert context.outcome =~ "published to origin/main"
        assert remote_head(context) == context.candidate
        {:ok, context}
      end
    end
  end

  spex "John changes the development branch to dev", criterion: 2388 do
    scenario "John selects dev in project settings" do
      given_ "a verified candidate and a dev branch", context do
        {:ok, context |> remote_project("dev") |> verified_candidate()}
      end

      when_ "John saves dev and promotes his story", context do
        {:ok, context |> choose_branch("dev") |> request_publication() |> outcome()}
      end

      then_ "dev receives the candidate and main stays unchanged", context do
        assert context.outcome =~ "published to origin/dev"
        assert remote_head(context) == context.candidate
        assert git!(context.origin, ["rev-parse", "refs/heads/main"]) == context.base
        {:ok, context}
      end
    end
  end
end
