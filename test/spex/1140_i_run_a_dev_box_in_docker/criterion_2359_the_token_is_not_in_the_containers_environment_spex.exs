defmodule CodeMySpecSpex.Story1140.Criterion2359Spex do
  @moduledoc """
  Story 1140 — I run a dev box in Docker.
  Criterion 2359 — The token is not in the container's environment.

  `docker inspect` shows a container's environment to anyone who can run it, so
  the token reaches the container as a read-only mounted file and the harness
  reads it from there.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.DevBoxHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The token is mounted, not exported", criterion: 2359 do
    scenario "Sam inspects his Docker box" do
      given_ "Sam's Docker box is running", context do
        Fixtures.install_workspace_runner(healthy?: true, serving: :serving)
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        {:ok, Map.put(context, :box, add_box(live, "docker-1", "docker"))}
      end

      when_ "anyone inspects the container", context do
        {:ok,
         Map.merge(context, %{
           env: Fixtures.workspace_instance_env(),
           files: Fixtures.workspace_mounted_files()
         })}
      end

      then_ "the token is not among its environment variables", context do
        refute Enum.any?(Map.values(context.env), &String.contains?(&1, context.box.token)),
               "the token is in the container's environment"

        {:ok, context}
      end

      then_ "and the harness reads it from a mounted file", context do
        assert context.box.token in Map.values(context.files),
               "no mounted file holds the token: #{inspect(Map.keys(context.files))}"

        {:ok, context}
      end
    end
  end
end
