defmodule CodeMySpec.Provisioning.EnvironmentSeedTest do
  @moduledoc """
  Seeding a project's environments is all-or-nothing, under concurrency.

  `list/1` creates the initial rows on first read, and provisioning reads it
  from several places at once — the page verifying its steps while a step
  runs. Inserting the rows one at a time let a reader land in the middle and
  get a single environment back, and the server step that did so built a box
  for production and never asked for UAT. Every read before and after it saw
  both, so the trace looked impossible; the step reported done and the deploy
  failed two steps later with "the provider has no such server".

  The cost of that shape is measured in ten-minute cloud cycles, so it is
  worth a test that runs in milliseconds.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Provisioning.EnvironmentRepository
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    {:ok, scope: full_scope_fixture()}
  end

  test "every concurrent reader sees the whole initial set", ctx do
    readers =
      for _ <- 1..12 do
        Task.async(fn -> EnvironmentRepository.list(ctx.scope) end)
      end

    results = Task.await_many(readers, 5_000)

    # Not "at least one reader got both" — every one of them. A reader that
    # gets a partial list is a step that provisions a partial project.
    for environments <- results do
      assert Enum.map(environments, & &1.name) |> Enum.sort() == ["prod", "uat"],
             "a reader saw #{inspect(Enum.map(environments, & &1.name))}"
    end
  end

  test "concurrent readers do not create duplicate rows", ctx do
    for _ <- 1..12 do
      Task.async(fn -> EnvironmentRepository.list(ctx.scope) end)
    end
    |> Task.await_many(5_000)

    names = EnvironmentRepository.list_existing(ctx.scope) |> Enum.map(& &1.name)

    assert Enum.sort(names) == ["prod", "uat"], "seeded #{inspect(names)}"
  end

  test "reading again returns the same rows rather than seeding a second set", ctx do
    first = EnvironmentRepository.list(ctx.scope)
    second = EnvironmentRepository.list(ctx.scope)

    assert Enum.map(first, & &1.id) == Enum.map(second, & &1.id)
  end

  test "production comes first, which is the order the steps fan out in", ctx do
    assert EnvironmentRepository.list(ctx.scope) |> Enum.map(& &1.name) == ["prod", "uat"]
  end
end
