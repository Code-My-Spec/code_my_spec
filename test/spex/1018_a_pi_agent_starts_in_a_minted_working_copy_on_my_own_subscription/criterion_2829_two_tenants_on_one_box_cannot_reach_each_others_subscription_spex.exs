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

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A shared box is not a shared credential" do
    scenario "Two tenants on one box cannot reach each other's subscription" do
      given_ "two tenants with working copies on one shared host, each with their own subscription",
             context do
        {:ok, context}
      end

      when_ "an agent starts on one tenant's copy", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartAgent.execute(%{"engine" => "pi", "provider" => "openai-codex"}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it is authenticated on that tenant's subscription only", context do
        refute context.response.isError, response_text(context.response)

        account_id = field(response_text(context.response), "Account")

        assert is_binary(account_id),
               "the started agent does not say whose credential it is running on, " <>
                 "so nothing can check it is the right tenant's. " <>
                 "Got: #{response_text(context.response)}"

        assert account_id == to_string(context.account.id),
               "the agent resolved a credential belonging to another account. " <>
                 "Got #{inspect(account_id)}, expected #{inspect(context.account.id)}"

        {:ok, context}
      end

      then_ "nothing it can read names the other tenant's credential", context do
        config_dir = field(response_text(context.response), "Config dir")

        assert config_dir =~ to_string(context.account.id) or
                 config_dir =~ to_string(context.project.id),
               "the agent's configuration directory is not scoped to this tenant. " <>
                 "Pi reads auth.json from that directory, and on a multi-tenant host " <>
                 "a shared one puts a subscription in a path another tenant's agent " <>
                 "can read — and an agent is a process that reads files for a living " <>
                 "and can be asked to read one. Got: #{config_dir}"

        {:ok, context}
      end
    end
  end

  # The tool replies in text, not structured content — `hybrid_response/2`
  # discards the data map on purpose, because a structured payload makes Claude
  # ignore the text beside it. So the contract is the labelled line.
  defp field(text, label) do
    case Regex.run(~r/^#{Regex.escape(label)}:[ ]*(.+)$/m, text) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end
end
