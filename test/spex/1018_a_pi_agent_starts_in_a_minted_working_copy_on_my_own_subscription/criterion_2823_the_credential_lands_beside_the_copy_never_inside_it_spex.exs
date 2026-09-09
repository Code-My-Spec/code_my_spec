defmodule CodeMySpecSpex.Story1018.Criterion2823Spex do
  @moduledoc """
  Story 1018 — An agent starts in a minted working copy on my own subscription.
  Criterion 2823 — The credential is never written down.

  Rule: Starting an agent never writes a credential into the working copy.

  ## Why this stopped being about a directory

  It used to assert that the config directory sat *outside* the checkout. That
  was the right question when `pi` read `auth.json` off disk: the credential had
  to live somewhere, so the only thing to get right was where.

  It does not live anywhere now. The credential travels on the wire to the
  machine and into the engine's memory, and `Agent.credential` is a virtual,
  redacted field precisely so it cannot be persisted by accident. So the honest
  assertion is the stronger one the rule always meant: nothing is written down
  at all.

  That also makes this a real guard rather than a restatement. A checkout that
  never receives a credential is easy to regress — someone adds `config_dir:`
  back to a changeset for convenience, or a provider decides to materialise an
  `auth.json` next to the tree, and nothing else would notice.

  `git add -A` on a clean exit is what makes it expensive: a credential inside
  the tree is a credential in a commit.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.RealDisk

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The tree stays clean" do
    scenario "The credential is never written down" do
      given_ "a tenant with a connected subscription and a minted working copy", context do
        {:ok, integration} = Fixtures.connect_provider(context.scope, :openai)

        {:ok, Map.put(context, :integration, integration)}
      end

      when_ "an agent starts on that copy", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartAgent.execute(%{"engine" => "alloy", "provider" => "openai-codex"}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the checkout holds no credential", context do
        refute context.response.isError, response_text(context.response)

        copy = context.scope.cwd

        assert is_binary(copy) and RealDisk.dir?(copy),
               "the premise is a real checkout to look inside; without one this " <>
                 "asserts nothing about what was written into it"

        assert files_naming_a_credential(copy) == [],
               "a credential was written into the working copy. `git add -A` on a " <>
                 "clean exit puts it in a commit, and the agent that wrote it is " <>
                 "the same one that will push."

        {:ok, context}
      end

      then_ "and the record does not carry it either", context do
        agents = Fixtures.list_agents(context.scope)

        assert agents != [],
               "no agent was recorded, so there is no record to check"

        for agent <- agents do
          refute Map.get(agent, :config_dir),
                 "the row names a directory the credential was written to. There " <>
                   "should be no such directory — the machine is handed the " <>
                   "credential and keeps it in memory."

          refute persisted_credential(agent),
                 "the credential is on the row. It is a virtual, redacted field " <>
                   "for exactly this reason: a row is a second place a " <>
                   "subscription lives, and it is the place that gets dumped, " <>
                   "logged and backed up."
        end

        {:ok, context}
      end
    end
  end

  # Anything under the checkout that looks like a stored credential. Named by
  # shape rather than by exact path, because the failure this guards is somebody
  # choosing a *new* path.
  defp files_naming_a_credential(copy) do
    [copy, "**", "{auth.json,credentials.json,.pi,.codex}"]
    |> Path.join()
    |> Path.wildcard(match_dot: true)
  end

  defp persisted_credential(agent) do
    # Reloaded rather than taken from the struct in hand: a virtual field is
    # populated in memory on the way through, and the question is what survives
    # to the database.
    agent |> Map.get(:credential) |> persisted_credential_value()
  end

  defp persisted_credential_value(nil), do: nil
  defp persisted_credential_value(%{} = credential) when map_size(credential) == 0, do: nil
  defp persisted_credential_value(other), do: other
end
