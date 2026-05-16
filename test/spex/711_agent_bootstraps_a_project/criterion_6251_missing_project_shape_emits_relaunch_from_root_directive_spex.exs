defmodule CodeMySpecSpex.Story711.Criterion6251Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6251 — Missing project shape emits relaunch-from-root directive.

  When the working directory lacks `mix.exs`, `Init.PhoenixProject.command/2`
  returns a prompt that:
    1. Tells the user to quit and relaunch Claude Code from the project root.
    2. Names the working directory the harness attached to (so the user
       can see what went wrong).

  Surface: `AgentTasks.Init.PhoenixProject.command/2`. Pure filesystem
  + string output — no shell outs, no cassette.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.AgentTasks.Init

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Init.PhoenixProject requires mix.exs + lib/ + config/ in cwd; otherwise emits relaunch guidance" do
    scenario "Missing project shape emits relaunch-from-root directive" do
      given_ "the working directory has no mix.exs", context do
        File.rm!(Path.join(context.scope.cwd, "mix.exs"))
        {:ok, context}
      end

      when_ "the agent calls Init.PhoenixProject.command on the scope",
            context do
        {:ok, prompt} = Init.PhoenixProject.command(context.scope, %{})
        {:ok, Map.put(context, :prompt, prompt)}
      end

      then_ "the prompt instructs the user to quit and relaunch Claude Code from the project root",
            context do
        assert context.prompt =~ ~r/re-?launch/i,
               "expected prompt to mention relaunching, got:\n#{context.prompt}"

        assert context.prompt =~ ~r/project root/i,
               "expected prompt to mention project root, got:\n#{context.prompt}"

        {:ok, context}
      end

      and_ "the prompt names the working directory the harness attached to",
           context do
        assert String.contains?(context.prompt, context.scope.cwd),
               "expected prompt to name the cwd `#{context.scope.cwd}`, got:\n#{context.prompt}"

        {:ok, context}
      end
    end
  end
end
