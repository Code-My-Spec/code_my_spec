defmodule CodeMySpecSpex.Story1018.Criterion2826Spex do
  @moduledoc """
  Story 1018 — A Pi agent starts in a minted working copy on my own subscription.
  Criterion 2826 — Two agents on one copy, different providers.

  Rule: The caller names the provider when starting an agent, and a new provider is
  a new integration rather than a new way to start one.

  Multi-provider is the destination, not a later extension, and this is what it
  costs to mean it: the provider is an argument, not ambient state. A machine-wide
  default would work perfectly for as long as everything wanted the same provider
  and then quietly answer the wrong one — the failure being that the second agent
  spends the wrong subscription, which nobody notices until a bill or a quota does.

  Two agents on one copy is the sharp case because it is where any ambient source
  — a config file, an environment variable, "the last one that started" — collapses
  to one answer for two callers who asked for different things.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.Integrations
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The provider is an argument, not ambient state" do
    scenario "Two agents on one copy, different providers" do
      given_ "several providers connected to CodeMySpec", context do
        {:ok, _openai} =
          Integrations.save_integration(
            context.scope,
            :openai,
            %{
              "access_token" => "spex-access",
              "refresh_token" => "spex-refresh",
              "expires_in" => 3600
            },
            %{"id" => "spex-chatgpt-account"}
          )

        {:ok, _zai} =
          Integrations.save_integration(
            context.scope,
            :zai,
            %{"access_token" => "spex-zai-key", "expires_in" => 31_536_000},
            %{"id" => "spex-zai-account"}
          )

        {:ok, context}
      end

      when_ "an engineer starts one agent naming each of two providers", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, first, _frame} =
          StartAgent.execute(%{"engine" => "pi", "provider" => "openai-codex"}, frame)

        {:reply, second, _frame} =
          StartAgent.execute(%{"engine" => "pi", "provider" => "zai"}, frame)

        {:ok, context |> Map.put(:first, first) |> Map.put(:second, second)}
      end

      then_ "each runs on the provider it was given", context do
        refute context.first.isError, response_text(context.first)
        refute context.second.isError, response_text(context.second)

        first_provider = field(response_text(context.first), "Provider")
        second_provider = field(response_text(context.second), "Provider")

        assert first_provider == "openai-codex",
               "the first agent is not on the provider it was asked for. " <>
                 "Got: #{inspect(first_provider)}"

        assert second_provider == "zai",
               "the second agent is not on the provider it was asked for. This is " <>
                 "how an ambient default fails: it answers correctly until two " <>
                 "callers want different things, then spends the wrong subscription " <>
                 "for one of them. Got: #{inspect(second_provider)}"

        {:ok, context}
      end

      then_ "neither inherited the other's, nor a machine-wide default", context do
        refute field(response_text(context.first), "Provider") ==
                 field(response_text(context.second), "Provider"),
               "both agents ended up on one provider, so the argument was ignored " <>
                 "in favour of something ambient. Nobody notices that until a quota " <>
                 "or a bill does."

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
