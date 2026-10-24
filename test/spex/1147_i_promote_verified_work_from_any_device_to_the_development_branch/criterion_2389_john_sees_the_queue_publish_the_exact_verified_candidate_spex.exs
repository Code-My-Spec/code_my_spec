defmodule CodeMySpecSpex.Story1147.Criterion2389Spex do
  @moduledoc "Story 1147: john sees the queue publish the exact verified candidate."
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

  spex "John receives publication evidence for the exact candidate", criterion: 2389 do
    scenario "the verified source commit is published without creating another commit" do
      given_ "a candidate certified at its exact commit", context do
        {:ok, context |> remote_project() |> verified_candidate()}
      end

      when_ "John promotes the story through its agent tool", context do
        {:ok, context |> request_publication() |> outcome()}
      end

      then_ "origin and the reported publication identify that candidate", context do
        assert context.outcome =~ "published to origin/main"
        assert context.outcome =~ context.candidate
        assert remote_head(context) == context.candidate
        assert git!(context.agent_root, ["rev-parse", "HEAD"]) == context.candidate
        {:ok, context}
      end
    end
  end
end
