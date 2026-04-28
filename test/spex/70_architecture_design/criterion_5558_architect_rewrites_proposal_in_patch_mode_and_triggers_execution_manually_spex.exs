defmodule CodeMySpecSpex.Story70.Criterion5558Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 5558 — Architect rewrites proposal in patch mode and triggers
  execution manually.

  When the change set warrants a full proposal rewrite (lots of new stories,
  larger restructure), the architect rewrites `proposal.md` and explicitly
  calls the `execute_proposal` MCP tool to apply it. The tool validates the
  proposal, creates new components, links stories, and writes spec stubs.

  Surface: writes proposal via the environment, then calls `execute_proposal`
  MCP tool. Verifies via `list_components` and a filesystem read for the new
  spec stub.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Architecture.Tools.ExecuteProposal
  alias CodeMySpec.McpServers.Components.Tools.ListComponents
  alias CodeMySpec.Paths
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The architect rewrites proposal in patch mode and triggers execution manually" do
    scenario "rewrite + manual execute creates new components and links stories" do
      given_ "the project has an existing component", context do
        proposal = Fixtures.proposal_with_context("MyApp", "Existing", "An existing context")

        {:ok, _result} =
          Fixtures.with_executed_proposal(context.scope, context.environment, proposal)

        {:ok, Map.put(context, :existing_module, "MyApp.Existing")}
      end

      given_ "a new unsatisfied story exists on the project", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "New story — needs feature",
            description: "Needs new feature",
            acceptance_criteria: ["New feature criterion"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      when_ "the architect rewrites the proposal end-to-end", context do
        app = context.project.module_name || "MyApp"
        story_id = context.story.id

        proposal = """
        # Architecture Proposal

        ## Surface Components

        ### #{app}Web.FeatureLive

        - **Type:** liveview
        - **Description:** New feature LiveView for the new story
        - **Stories:** #{story_id}

        ## Contexts

        ### #{app}.Existing

        - **Type:** context
        - **Description:** An existing context

        ### #{app}.Feature

        - **Type:** context
        - **Description:** Feature domain

        ## Dependencies

        - #{app}Web.FeatureLive -> #{app}.Feature
        """

        :ok =
          CodeMySpec.Environments.write_file(
            context.environment,
            Paths.proposal_path(),
            proposal
          )

        {:ok, context}
      end

      when_ "the architect calls execute_proposal", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ExecuteProposal.execute(%{}, frame)

        {:ok, Map.put(context, :execute_response, response)}
      end

      then_ "the tool reports success", context do
        refute context.execute_response.isError,
               "expected execute_proposal to succeed, got: #{inspect(context.execute_response)}"

        {:ok, context}
      end

      then_ "the new components show up in list_components", context do
        app = context.project.module_name || "MyApp"
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ListComponents.execute(%{}, frame)
        body = response_text(response)

        for module_name <- ["#{app}Web.FeatureLive", "#{app}.Feature"] do
          assert body =~ module_name,
                 "expected #{module_name} in list_components, got: #{inspect(body)}"
        end

        {:ok, context}
      end

      then_ "the existing component is preserved", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ListComponents.execute(%{}, frame)
        body = response_text(response)

        assert body =~ context.existing_module,
               "expected pre-existing #{context.existing_module} to be preserved, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "spec stubs exist for the new components", context do
        app = context.project.module_name || "MyApp"

        for module_name <- ["#{app}Web.FeatureLive", "#{app}.Feature"] do
          spec_path = Paths.spec_file(Macro.underscore(module_name))

          assert CodeMySpec.Environments.file_exists?(context.environment, spec_path),
                 "expected stub spec at #{spec_path} to be created by execute_proposal"
        end

        {:ok, context}
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: text} -> text
      %{"text" => text} -> text
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)
end
