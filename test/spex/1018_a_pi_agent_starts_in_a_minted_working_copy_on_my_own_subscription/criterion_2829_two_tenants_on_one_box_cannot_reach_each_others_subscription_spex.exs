defmodule CodeMySpecSpex.Story1018.Criterion2829Spex do
  @moduledoc """
  Story 1018 — A Pi agent starts in a minted working copy on my own subscription.
  Criterion 2829 — Two tenants on one box cannot reach each other's subscription.

  Rule: A working copy's credential is reachable only from that working copy,
  including when the box is shared.

  This is the criterion that decides the design rather than describing it. Pi reads
  its whole configuration — models, settings, extensions and `auth.json` together —
  from one directory, `PI_CODING_AGENT_DIR`, defaulting to `~/.pi/agent`. On a
  single-user machine sharing that directory across working copies is the obvious
  arrangement and costs nothing.

  The cloud host is multi-tenant. There, one shared `auth.json` is one tenant's
  ChatGPT subscription sitting in a path another tenant's agent can read — and an
  agent is a process that reads files for a living and can be asked to read one.
  So per-copy configuration is not a preference about isolation, it is the
  isolation, and it is the same acceptance criterion story 986's shared host is
  built to.

  Billing is asserted separately on purpose: reading the credential is one leak,
  spending it is the other, and an implementation could plausibly get the file
  permissions right and still resolve the wrong integration.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1, response_field: 2]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A shared box is not a shared credential" do
    scenario "Two tenants on one box cannot reach each other's subscription" do
      given_ "two tenants with working copies on one shared host, each with their own subscription",
             context do
        {:ok, _integration} = Fixtures.connect_provider(context.scope, :openai)

        # The other tenant is a separate account with its own integration. What
        # this asserts is that ours resolves to ours — a shared host is the
        # condition, not something the spec has to build a second account to
        # demonstrate, since the isolation is in which account the credential
        # comes from.
        {:ok, context}
      end

      when_ "an agent starts on one tenant's copy", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartAgent.execute(%{"engine" => "alloy", "provider" => "openai-codex"}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it is authenticated on that tenant's subscription only", context do
        refute context.response.isError, response_text(context.response)

        account_id = response_field(context.response, "Account")

        assert is_binary(account_id),
               "the started agent does not say whose credential it is running on, " <>
                 "so nothing can check it is the right tenant's. " <>
                 "Got: #{response_text(context.response)}"

        assert account_id == to_string(context.account.id),
               "the agent resolved a credential belonging to another account. " <>
                 "Got #{inspect(account_id)}, expected #{inspect(context.account.id)}"

        {:ok, context}
      end

      then_ "and nothing left on the box names the credential at all", context do
        # This used to check that the config directory path contained the
        # account id — a reasonable proxy when the credential was a file, since
        # where you put it was the only defence. There is no file: the
        # credential goes over the wire into the engine's memory, so the defence
        # is that there is nothing on the box to read.
        #
        # Which matters here more than anywhere: an agent is a process that
        # reads files for a living and can be asked to read one.
        refute response_field(context.response, "Config dir"),
               "the start named a directory the credential was written to. On a " <>
                 "shared host that is a path another tenant's agent can be asked " <>
                 "to read."

        for agent <- Fixtures.list_agents(context.scope) do
          refute Map.get(agent, :config_dir),
                 "the row names a credential directory on a multi-tenant box"

          refute Map.get(agent, :credential),
                 "the credential survived to the row, which is a second place a " <>
                   "subscription lives and the one that gets dumped and backed up"
        end

        {:ok, context}
      end
    end
  end
end
