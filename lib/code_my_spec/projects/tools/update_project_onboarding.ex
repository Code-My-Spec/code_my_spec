defmodule CodeMySpec.Projects.Tools.UpdateProjectOnboarding do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool
  alias CodeMySpec.Projects.{Onboarding, Tools}

  @choices ~w(description starting_point destination destination_path)
  @source_fields ~w(source_kind repository_url ref device_id path)

  @impl true
  def name, do: "update_project_onboarding"

  @impl true
  def description do
    """
    Record agreed choices on the connected project without a working copy. All arguments are
    top-level fields; do not wrap them in onboarding or sources. Omitted fields are preserved.
    For local development use local_directory from get_project_onboarding unless the user chooses
    another folder. Set destination to local, cloud, or external; destination_path is a folder.
    A fresh Phoenix app with reference repositories still has starting_point=new.
    To add a reference, pass source_kind and repository_url (GitHub), or device_id and path (local).
    To edit a saved source, also pass its source_id. Other sources are preserved. Call once per source.
    Use source_action=remove with source_id to remove one, or source_action=clear to remove all.
    Read get_project_onboarding for source IDs and accessible device IDs. Never invent assessments.
    Saving does not inspect, clone, provision, or modify code. Renaming does not move existing files.
    """
  end

  @impl true
  def params do
    %{
      name: {:meta, :string, [description: "Project display name."]},
      description: {:meta, :string, [description: "Brief project synopsis and audience."]},
      starting_point:
        {:meta, {:enum, ~w(new existing)},
         [description: "new or existing. References for a fresh app still mean new."]},
      destination:
        {:meta, {:enum, ~w(local cloud external)},
         [description: "Development host: local, cloud, or external."]},
      destination_path:
        {:meta, :string,
         [
           description:
             "Optional absolute folder on the development host, only when explicitly chosen."
         ]},
      source_action:
        {:meta, {:enum, ~w(upsert remove clear)},
         [
           description:
             "upsert (default when source fields supplied), remove, or clear. Omit to leave sources unchanged."
         ]},
      source_id:
        {:meta, :string,
         [description: "Existing source ID to edit or remove. Omit to add a source."]},
      source_kind:
        {:meta, {:enum, ~w(github local)},
         [description: "github or local; required when adding a source."]},
      repository_url: {:meta, :string, [description: "GitHub URL for this source."]},
      ref: {:meta, :string, [description: "Optional source branch or tag."]},
      device_id: {:meta, :string, [description: "Accessible device ID for a local source."]},
      path:
        {:meta, :string,
         [description: "Absolute local source folder; distinct from destination_path."]}
    }
  end

  @impl true
  def call(params, context), do: params |> script_result(context) |> Tools.text()

  @impl true
  def script_result(params, context) do
    with :ok <- validate_input(params),
         {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, project} <- Onboarding.fetch(scope),
         {:ok, attrs} <- attributes(params, project),
         {:ok, project} <- Onboarding.save(scope, attrs) do
      {:ok, Tools.snapshot(project, scope)}
    else
      {:error, reason} -> Tools.error(reason)
    end
  end

  @impl true
  def validate_input(params) do
    allowed = params() |> Map.keys() |> Enum.map(&to_string/1)
    unknown = params |> Map.keys() |> Enum.map(&to_string/1) |> Enum.reject(&(&1 in allowed))

    case unknown do
      [] ->
        :ok

      fields ->
        {:error,
         "Unsupported fields: #{Enum.join(fields, ", ")}. Pass fields at the top level: #{Enum.join(allowed, ", ")}. Nothing was saved; correct the fields and retry."}
    end
  end

  defp attributes(params, project) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)
    attrs = Map.take(params, ["name"]) |> Map.put("onboarding", Map.take(params, @choices))

    source? =
      Enum.any?(["source_action", "source_id" | @source_fields], &Map.has_key?(params, &1))

    if source? do
      existing =
        Enum.map(project.sources, fn source ->
          source |> Map.from_struct() |> Map.new(fn {k, v} -> {to_string(k), v} end)
        end)

      with {:ok, sources} <- update_sources(existing, params) do
        {:ok, Map.put(attrs, "sources", sources)}
      end
    else
      {:ok, attrs}
    end
  end

  defp update_sources(existing, params) do
    id = params["source_id"]
    current = Enum.find(existing, &(&1["id"] == id))
    action = params["source_action"] || "upsert"

    cond do
      action == "clear" ->
        {:ok, []}

      id && is_nil(current) ->
        {:error, "source_id does not belong to this project. Nothing was saved."}

      action == "remove" && is_nil(id) ->
        {:error, "source_id is required to remove a source."}

      action == "remove" ->
        {:ok, Enum.reject(existing, &(&1["id"] == id))}

      action == "upsert" ->
        changes = Map.take(params, @source_fields)

        changes =
          if Map.has_key?(changes, "source_kind"),
            do: changes |> Map.put("kind", changes["source_kind"]) |> Map.delete("source_kind"),
            else: changes

        source = Map.merge(current || %{}, changes)

        {:ok,
         if(current,
           do: Enum.map(existing, &if(&1["id"] == id, do: source, else: &1)),
           else: existing ++ [source]
         )}

      true ->
        {:error, "source_action must be upsert, remove, or clear."}
    end
  end
end
