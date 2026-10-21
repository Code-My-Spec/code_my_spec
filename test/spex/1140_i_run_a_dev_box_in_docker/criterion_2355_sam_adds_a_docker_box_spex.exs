defmodule CodeMySpecSpex.Story1140.Criterion2355Spex do
  @moduledoc """
  Story 1140 — I run a dev box in Docker.
  Criterion 2355 — Sam adds a Docker box.

  Docker is a provider like the others: a radio on the add form, backed by
  `Workspaces.Runner.Docker` (the Dev boxes page lists `Runner.dev_boxes/0`).
  Adding the box starts its container through the configured workspace runner,
  here the fake one, which records the call, and the box signs in with the token
  it was given.
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

  spex "Adding a Docker box starts its container", criterion: 2355 do
    scenario "Sam picks Docker" do
      given_ "Sam's machine runs Docker", context do
        Fixtures.install_workspace_runner(healthy?: true, serving: :serving)
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        {:ok, Map.put(context, :live, live)}
      end

      when_ "he adds a dev box and picks Docker", context do
        add_dev_box(context.live, "docker-1", "docker")

        {:ok,
         Map.merge(context, %{
           box_id: box_device_id(context.live, "docker-1"),
           token: shown_token(context.live)
         })}
      end

      then_ "a container is started for it", context do
        assert Fixtures.workspace_instance_env() != %{},
               "no container was started for the Docker box"

        {:ok, context}
      end

      then_ "and it connects as that box", context do
        assert exchanged(context.token)["device_id"] == context.box_id
        {:ok, context}
      end
    end
  end
end
