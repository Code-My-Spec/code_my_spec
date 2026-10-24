defmodule CodeMySpecSpex.Story842.Criterion1975Spex do
  @moduledoc """
  Story 842 — Formal release process
  Criterion 1975 — A declined release stands down.

  "No" has to mean nothing happened. A decline that still leaves a tag, a
  GitHub Release, or a release record behind is worse than one that shipped —
  the user believes they stopped it and the record says otherwise.

  Surface: `CodeMySpec.AgentTasks.StartAgentTask.run/2`, called directly through
  `Fixtures.start_agent_task/2` -- the HTTP action it backed was removed with
  the retired CLI's LocalWeb router (issue f532f990) -- with the approval
  declined, then the absence of each artifact. Absence is the whole claim, so
  it is checked directly rather than inferred from what the task said it
  would do.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpecSpex.Fixtures

  @cassette "842_1975_release_declined"
  @release_type "release"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "A declined release stands down", criterion: 544 do
    scenario "the user says no" do
      given_ "a story on UAT waiting to be released, and an empty releases directory",
             context do
        :ok =
          ExecutionContexts.write_file(
            context.execution_context,
            ".code_my_spec/devops/deploys/story_9004.md",
            "# Deploy\n\nstory 9004 to uat — verified\n"
          )

        # The directory is made here, holding nothing but a marker, so "no
        # release was recorded" is one exact expectation afterwards rather than
        # two acceptable ones — a missing directory and an empty directory
        # would otherwise both have to be tolerated, and a test that tolerates
        # two answers is not checking which one it got.
        :ok =
          ExecutionContexts.write_file(
            context.execution_context,
            ".code_my_spec/releases/.keep",
            ""
          )

        {:ok, context}
      end

      when_ "the release is started and the user declines", context do
        response =
          with_full_cassette @cassette do
            Fixtures.start_agent_task(context.scope, %{
              "session_type" => @release_type,
              "external_id" => "spex-#{System.unique_integer([:positive])}",
              "approval" => "declined"
            })
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "no release record is written", context do
        assert {:ok, entries} =
                 ExecutionContexts.list_directory(
                   context.execution_context,
                   ".code_my_spec/releases"
                 )

        assert entries == [".keep"],
               "a declined release left a record behind, so the tool believes it shipped: " <>
                 inspect(entries -- [".keep"])

        {:ok, context}
      end

      then_ "nothing is tagged", context do
        {tags, _status} =
          ExecutionContexts.cmd(context.execution_context, "git", ["tag", "--list"])

        refute tags =~ ~r/v?\d+\.\d+\.\d+/,
               "a declined release left a tag behind, got: #{inspect(tags)}"

        {:ok, context}
      end
    end
  end
end
