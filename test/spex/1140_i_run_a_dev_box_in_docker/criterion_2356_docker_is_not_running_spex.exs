defmodule CodeMySpecSpex.Story1140.Criterion2356Spex do
  @moduledoc """
  Story 1140 — I run a dev box in Docker.
  Criterion 2356 — Docker is not running.

  The runner reports `{:error, :docker_unreachable}` when no daemon answers
  (the Docker runner maps a missing CLI and a refused socket to it); the page
  says so and leaves no box behind.
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

  spex "A missing Docker daemon is said plainly and leaves nothing half-made", criterion: 2356 do
    scenario "Sam picks Docker with no daemon" do
      given_ "Sam picks Docker but no Docker daemon answers", context do
        Fixtures.install_docker_dev_box_runner(start_result: {:error, :docker_unreachable})
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        {:ok, Map.put(context, :live, live)}
      end

      when_ "he adds the box", context do
        {:ok, Map.put(context, :html, add_dev_box(context.live, "docker-1", "docker"))}
      end

      then_ "he is told Docker is not reachable", context do
        assert context.html =~ ~r/Docker.{0,40}not reachable/is,
               "the page did not say Docker is not reachable: #{context.html}"

        {:ok, context}
      end

      then_ "and no box is left half-made", context do
        {:ok, fresh, _html} = open_dev_boxes(context.conn, context.project)
        refute has_element?(fresh, "[data-test='dev-box']")
        {:ok, context}
      end
    end
  end
end
