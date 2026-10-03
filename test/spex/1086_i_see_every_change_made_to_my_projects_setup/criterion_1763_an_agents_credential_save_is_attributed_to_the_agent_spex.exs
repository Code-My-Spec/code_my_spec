defmodule CodeMySpecSpex.Story1086.Criterion1763Spex do
  @moduledoc """
  Story 1086 — I see every change made to my project's setup
  Criterion 1763 — An agent's credential save is attributed to the agent.

  `Agents.actor/2` already names a calling agent distinctly from a person
  ("the coding agent <id>" rather than an email) for every other record
  that attributes an action — this is that same function, used here for
  the first time by something an agent, not a person, actually calls:
  `SaveProviderCredential`, the MCP tool that lets an agent put a Hetzner,
  Cloudflare or Resend key on file without a person at the console form.

  Surface: `CodeMySpec.McpServers.Devops.Tools.SaveProviderCredential`,
  driving `CodeMySpec.Activity`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.McpServers.Devops.Tools.SaveProviderCredential

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "An agent's credential save is attributed to the agent", criterion: 1763 do
    scenario "the coding agent saves the Hetzner token" do
      given_ "a coding agent is on this project", context do
        agent = CodeMySpecSpex.Fixtures.running_agent(context.scope, role: "coding")
        {:ok, Map.put(context, :agent, agent)}
      end

      when_ "it saves the Hetzner API token", context do
        frame = %Anubis.Server.Frame{
          assigns: %{current_scope: context.scope, agent_id: context.agent.id}
        }

        {:reply, _response, _frame} =
          SaveProviderCredential.execute(
            %{key: "hetzner_api_token", value: "hetzner-secret-value"},
            frame
          )

        {:ok, context}
      end

      then_ "Activity attributes the save to the agent, not a person", context do
        {:ok, activity_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/activity")

        document = activity_view |> render() |> Floki.parse_document!()

        entries = Floki.find(document, "[data-test='activity-entry'][data-kind='credential_save']")

        assert entries != [], "the agent's credential save never reached Activity"

        [actor] = Floki.attribute(entries, "data-actor")

        assert actor =~ "coding agent #{context.agent.id}",
               "expected the entry attributed to the coding agent, got #{inspect(actor)}"

        refute actor =~ "@",
               "the entry reads like a person's email rather than the agent that made the call"

        {:ok, context}
      end
    end
  end
end
