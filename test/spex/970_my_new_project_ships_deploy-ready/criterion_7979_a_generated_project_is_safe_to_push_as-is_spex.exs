defmodule CodeMySpecSpex.Story970.Criterion7979Spex do
  @moduledoc """
  Story 970 — My new project ships deploy-ready
  Criterion 7979 — A generated project is safe to push as-is.

  A freshly generated project carries encrypted secret scaffolding and no
  plaintext environment file, so `git push` on the very first commit
  exposes nothing. Generators that scaffold a `.env` and trust the
  `.gitignore` leak on the first mistake.

  ## Surface note

  These criteria describe the *output of the cms_new generator*, which lives
  in a separate repository. The spex boundary reaches `Environments`,
  `McpServers`, `Fixtures` and `Web` — not that generator. The `given_`
  therefore drives generation through the harness's generator surface; if no
  such surface exists, this story's real verification is a QA pass against
  `cms.new` output rather than a spex. Flagged rather than fudged.

  Surface: filesystem — the generated project tree.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  # A real directory on disk, shared with the page. The generator writes
  # through the project's registered environment; a spex holding its own
  # in-memory one reads an empty tree and concludes nothing was generated.
  setup :real_working_directory

  spex "A generated project is safe to push as-is" do
    scenario "the tree carries encrypted scaffolding and no plaintext env file" do
      given_ "Sam generates a project", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view |> element("[data-test='generate-project']") |> render_click()

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he looks for its environment files", context do
        top = project_tree(context.environment)

        # `list_directory/2` lists one level, so the env files have to be asked
        # for where they live. Prefixed back to full paths, because what the
        # assertions below are about is the *shape* — `envs/…​.enc.…` present,
        # a plaintext `.env` absent — not which directory the listing came from.
        envs =
          context.environment
          |> Environments.list_directory("envs")
          |> env_paths()

        entries = top ++ envs

        {:ok, Map.put(context, :entries, entries)}
      end

      then_ "he finds encrypted secret scaffolding", context do
        encrypted =
          Enum.filter(context.entries, fn path ->
            String.contains?(path, "envs/") and String.contains?(path, ".enc.")
          end)

        # Anchor: the generator produced env scaffolding at all, so the
        # absence of plaintext below is meaningful.
        assert encrypted != [],
               "expected encrypted environment scaffolding in the generated project, entries: #{inspect(context.entries)}"

        {:ok, context}
      end

      then_ "and no plaintext environment file", context do
        plaintext =
          Enum.filter(context.entries, fn path ->
            Path.basename(path) in [".env", ".env.local", ".env.production", ".env.schema"]
          end)

        assert plaintext == [],
               "expected no plaintext environment file in a freshly generated project, found: #{inspect(plaintext)}"

        {:ok, context}
      end

      then_ "pushing the repo exposes no secret", context do
        # Any file the generator wrote that carries a secret-shaped value
        # would ship on the first push.
        offenders = Enum.filter(context.entries, &carries_secret?(context.environment, &1))

        assert offenders == [],
               "expected no generated file to carry a real secret value, found in: #{inspect(offenders)}"

        {:ok, context}
      end
    end
  end

  defp env_paths({:ok, names}), do: Enum.map(names, &("envs/" <> &1))
  defp env_paths(_error), do: []

  defp carries_secret?(environment, path) do
    environment
    |> Environments.read_file(path)
    |> secret_body?()
  end

  defp secret_body?({:ok, body}),
    do: body =~ ~r/(SECRET_KEY_BASE|CLOAK_KEY|AGE-SECRET-KEY)\s*=\s*\S+/

  defp secret_body?(_error), do: false
end
