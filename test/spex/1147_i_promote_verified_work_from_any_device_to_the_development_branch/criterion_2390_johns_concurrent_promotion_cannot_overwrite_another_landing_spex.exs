defmodule CodeMySpecSpex.Story1147.Criterion2390Spex do
  @moduledoc "Story 1147: johns concurrent promotion cannot overwrite another landing."
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

  spex "John's promotion preserves a competing landing", criterion: 2390 do
    scenario "origin advances between certification and the push" do
      given_ "a verified candidate and a competing publication racing its push", context do
        {:ok, context |> remote_project() |> verified_candidate() |> concurrent_landing()}
      end

      when_ "John promotes and the rebuilt candidate passes its new gate", context do
        {:ok, context |> request_publication() |> gate_answers() |> outcome()}
      end

      then_ "both engineers' work is on origin and the published head is the new gate head",
            context do
        assert context.outcome =~ "published to origin/main"
        published = remote_head(context)

        assert git!(context.origin, ["merge-base", context.competitor, published]) ==
                 context.competitor

        assert git!(context.origin, ["merge-base", context.candidate, published]) ==
                 context.candidate

        assert published == git!(context.gate_root, ["rev-parse", "HEAD"])

        assert git!(context.origin, ["show", "#{published}:other.txt"]) ==
                 "Another engineer's work"

        {:ok, context}
      end
    end
  end
end
