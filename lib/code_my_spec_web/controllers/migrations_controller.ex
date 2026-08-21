defmodule CodeMySpecWeb.MigrationsController do
  @moduledoc """
  Where a local harness hands its project to the cloud.

  One request carries one project's authored graph and lands in one
  transaction. Story 991 asks for that directly — a migration that half-lands
  leaves Sam working out what arrived before he can retry, which is worse than
  one that plainly failed.

  Deliberately not per-entity CRUD. Ninety stories, eight hundred criteria and
  five hundred rules is ~1,500 round trips with the ordering re-derived on the
  client each time, and any interruption strands the project half-copied.
  """
  use CodeMySpecWeb, :controller

  require Logger

  alias CodeMySpec.Migration

  def create(conn, params) do
    scope = conn.assigns.current_scope

    case Migration.import_project(scope, params) do
      {:ok, summary} ->
        json(conn, %{"status" => "ok", "migrated" => summary})

      {:error, reason} ->
        Logger.warning("[Migration] refused: #{inspect(reason)}")

        conn
        |> put_status(422)
        |> json(%{"status" => "error", "reason" => describe(reason)})
    end
  end

  # The reason is for a person deciding what to do next, so it names the record
  # that could not be placed rather than echoing a changeset.
  defp describe(:plan_required),
    do:
      "migrating a project into the cloud needs a paid plan — free accounts can " <>
        "work here, but bringing in a project from a local harness is not free"

  defp describe({:unknown_story, id}),
    do: "a rule or scenario referenced story #{inspect(id)}, which is not in the payload"

  defp describe({:unknown_persona_link, link}),
    do: "a persona link referenced something not in the payload: #{inspect(link)}"

  # Named rather than inspected, because this one needs a decision from the
  # person: a project's titles are unique, so two source stories sharing one
  # cannot both land, and no import can choose which of them to keep. Before
  # this it surfaced as a 500 on `stories_title_project_id_index` naming
  # neither the title nor either story.
  defp describe({:duplicate_title, title, first_id, second_id}) do
    "stories #{inspect(first_id)} and #{inspect(second_id)} are both titled " <>
      "#{inspect(title)}, and a project's story titles are unique. Rename one " <>
      "in the source and export again — the import cannot choose between them."
  end

  defp describe(%Ecto.Changeset{} = changeset),
    do: inspect(Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end))

  defp describe(other), do: inspect(other)
end
