defmodule CodeMySpecSpex.Story1018.Criterion2823Spex do
  @moduledoc """
  Story 1018 — A Pi agent starts in a minted working copy on my own subscription.
  Criterion 2823 — The credential lands beside the copy, never inside it.

  Rule: Starting an agent never writes a credential into the working copy.

  A working copy is a git repository whose whole purpose is to be committed and
  pushed. Anything written into it is a thing that can be committed by an agent
  that was told to commit its work — and `agent.sh` does exactly that on a clean
  exit, with `git add -A`. A credential inside the tree is therefore not a risk of
  leaking; it is a scheduled leak with a supervisor to carry it out.

  The per-copy configuration directory makes this sharper rather than softer. We
  now mint a credential file per working copy on purpose, so "outside the tree" is
  the only thing standing between one and the other.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1, response_field: 2]

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The tree stays clean" do
    scenario "The credential lands beside the copy, never inside it" do
      given_ "a minted working copy", context do
        {:ok, _integration} = Fixtures.connect_provider(context.scope, :openai)
        :ok = Environments.register(context.project.id, context.environment)

        # A minted copy is a project, not an empty directory. It also has to
        # contain *something* for the tree to be listable at all — and a copy
        # with no files could not carry a credential either, which would make
        # this criterion pass for the wrong reason.
        :ok = Environments.write_file(context.environment, "mix.exs", "defmodule App.MixProject do
end
")

        {:ok, context}
      end

      when_ "a Pi agent is started on it with its own config directory", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartAgent.execute(%{"engine" => "pi", "provider" => "openai-codex"}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "no auth file was written anywhere inside the copy", context do
        # The real path, because `PiConfig` writes through the real filesystem —
        # asking the in-memory environment would answer about a different tree
        # than the one a credential would actually land in.
        {:ok, listing} = File.ls(context.scope.cwd)

        refute Enum.any?(listing, &(&1 =~ "auth.json")),
               "an auth file landed inside the working copy. That copy gets " <>
                 "committed — `agent.sh` runs `git add -A` on a clean exit — so a " <>
                 "credential in the tree is not a risk of leaking but a scheduled " <>
                 "one. Found: #{inspect(listing)}"

        refute Enum.any?(listing, &(&1 == ".pi")),
               "Pi's configuration directory was placed inside the working copy. " <>
                 "It holds auth.json. Found: #{inspect(listing)}"

        {:ok, context}
      end

      then_ "the config directory the agent runs against sits outside the copy", context do
        config_dir = response_field(context.response, "Config dir")

        assert is_binary(config_dir),
               "the response does not say where the agent's config directory is, so " <>
                 "nothing can check that it is outside the tree. " <>
                 "Got: #{response_text(context.response)}"

        refute String.starts_with?(config_dir, context.scope.cwd),
               "the per-copy config directory is inside the working copy. Per-copy " <>
                 "is required — the cloud host is multi-tenant and one shared auth " <>
                 "file would put a tenant's subscription in reach of another — but " <>
                 "per-copy must mean beside the copy, not in it. Got: #{config_dir}"

        {:ok, context}
      end
    end
  end
end
