defmodule CodeMySpecSpex.Story1077.Criterion4677Spex do
  @moduledoc """
  Story 1077 — A spec file names its criterion by number
  Criterion 4677 — A spec on another working copy does not cover this one.

  Covers Rule "A story's specs exist when every active criterion has a valid
  spec on this working copy". A spec another checkout has written is not on
  this one's disk.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.CriterionScript
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket

  @endpoint CodeMySpecWeb.Endpoint
  @contract_version CodeMySpecWeb.HarnessProjectChannel.contract_version()

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Coverage is per working copy", criterion: 1553 do
    scenario "a valid spec exists only on another working copy" do
      given_ "a valid spec naming the criterion exists only on working copy B", context do
        story = CriterionScript.create_story(context.scope, "Story A", ["A thing happens"])
        [number] = context.scope |> CriterionScript.story_text(story) |> CriterionScript.numbers()

        {:ok, reply, _socket} =
          UserSocket
          |> socket("working_copy_b", %{scope: context.scope})
          |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{context.project.id}", %{
            "contract_version" => @contract_version,
            "harness_id" => nil,
            "root" => "/workspace/working-copy-b",
            "label" => "working copy B",
            "device" => %{"id" => Fixtures.device_fixture(context.scope).id}
          })

        copy_b = reply["harness_id"] || reply[:working_copy_id]

        :ok =
          Environments.write_file(
            context.environment,
            "test/spex/story_a/a_thing_happens_spex.exs",
            CriterionScript.spex_naming(number)
          )

        Fixtures.deliver_manifest(%{context.scope | active_working_copy_id: copy_b})

        {:ok, Map.merge(context, %{story: story, number: number})}
      end

      when_ "working copy A computes its graph", context do
        {:ok, Map.put(context, :text, CriterionScript.specs_requirement(context.scope, context.story))}
      end

      then_ "the criterion is uncovered on working copy A", context do
        assert context.text =~ "**Status:** Not satisfied",
               "the spec is only on working copy B. Got:\n#{context.text}"

        assert context.text =~ "criterion #{context.number}"

        {:ok, context}
      end
    end
  end
end
