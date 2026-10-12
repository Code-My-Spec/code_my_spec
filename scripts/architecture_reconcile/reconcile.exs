# One-off only. Run with mix run --no-compile --no-start <this file> -- <options>.
# Export module call evidence with export_calls.exs first. No application services
# are started: writes use the existing Components APIs and their durable events.
defmodule Mix.Tasks.Cms.ReconcileArchitecture do
  use Mix.Task
  import Ecto.Query
  alias CodeMySpec.{Components, Files, Repo}
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Files.ComponentExtract
  alias CodeMySpec.Users.Scope

  def run(args) do
    opts =
      OptionParser.parse!(args,
        strict: [
          database: :string,
          project: :string,
          copy: :string,
          user: :string,
          xref: :string,
          report: :string,
          apply: :boolean
        ]
      )
      |> elem(0)

    Enum.each([:database, :project, :copy, :user, :xref, :report], &Keyword.fetch!(opts, &1))
    start_repo(opts[:database])

    project =
      Repo.one!(
        from p in CodeMySpec.Projects.Project,
          where: p.id == ^opts[:project],
          select: %{id: p.id, account_id: p.account_id}
      )

    user = Repo.get_by!(CodeMySpec.Users.User, email: opts[:user])

    scope = %Scope{
      user: user,
      active_project_id: project.id,
      active_account_id: project.account_id,
      active_working_copy_id: opts[:copy]
    }

    true =
      Repo.exists?(
        from c in CodeMySpec.WorkingCopies.WorkingCopy,
          where: c.id == ^opts[:copy] and c.project_id == ^project.id
      )

    xref = opts[:xref] |> File.read!() |> Jason.decode!()
    components = Repo.all(from c in Component, where: c.project_id == ^project.id)
    known = Map.new(components, &{&1.module_name, &1})
    # Never assign a secondary module's calls to the primary module of its file.
    # Generated/unrecorded modules are reported, not silently mapped to a parent.
    modules =
      xref["modules"]
      |> Enum.filter(&Map.has_key?(known, &1["name"]))
      |> Map.new(fn m ->
        {m["name"],
         %{
           name: m["name"],
           path: m["path"],
           content: File.read!(m["path"]),
           id: known[m["name"]].id
         }}
      end)

    missing = []

    evidence =
      Enum.filter(xref["evidence"], fn e ->
        Map.has_key?(modules, e["source"]) and Map.has_key?(modules, e["target"])
      end)

    desired =
      for e <- evidence,
          e["source"] != e["target"],
          into: MapSet.new(),
          do: {modules[e["source"]].id, modules[e["target"]].id}

    covered = MapSet.new(Map.values(modules), & &1.id)
    existing = Components.list_dependencies(scope)
    by_pair = Map.new(existing, &{{&1.source_component_id, &1.target_component_id}, &1})
    adds = MapSet.difference(desired, MapSet.new(Map.keys(by_pair))) |> Enum.sort()

    removes =
      Enum.filter(existing, fn d ->
        MapSet.member?(covered, d.source_component_id) and
          MapSet.member?(covered, d.target_component_id) and
          not MapSet.member?(desired, {d.source_component_id, d.target_component_id})
      end)

    updates =
      Enum.filter(
        existing,
        &(!&1.in_code and
            MapSet.member?(desired, {&1.source_component_id, &1.target_component_id}))
      )

    names =
      Map.new(components, &{&1.id, &1.module_name})
      |> Map.merge(Map.new(Map.values(modules), &{&1.id, &1.name}))

    pair = fn {a, b} -> %{source: names[a], target: names[b]} end

    report = %{
      extraction: "boundary calls and struct expansions; alias-only references excluded",
      manifest_sha256: xref["manifest_sha256"],
      evidence: evidence,
      unresolved_module_references: xref["references_only"],
      unmapped_compiled_modules: Enum.reject(xref["modules"], &Map.has_key?(known, &1["name"])),
      database: opts[:database],
      project: project.id,
      working_copy: opts[:copy],
      head: System.cmd("git", ["rev-parse", "HEAD"]) |> elem(0) |> String.trim(),
      new_components: Enum.map(missing, & &1.name),
      add: Enum.map(adds, pair),
      remove:
        Enum.map(
          removes,
          &Map.merge(pair.({&1.source_component_id, &1.target_component_id}), %{
            id: &1.id,
            provenance: &1.provenance
          })
        ),
      mark_in_code: Enum.map(updates, & &1.id),
      preserved_outside_compiled_snapshot:
        Enum.count(
          existing,
          &(not MapSet.member?(covered, &1.source_component_id) or
              not MapSet.member?(covered, &1.target_component_id))
        ),
      before_components:
        Enum.map(
          components,
          &Map.take(&1, [:id, :name, :module_name, :type, :parent_component_id, :provenance])
        ),
      before_dependencies:
        Enum.map(
          existing,
          &Map.take(&1, [:id, :source_component_id, :target_component_id, :provenance, :in_code])
        )
    }

    File.write!(opts[:report], Jason.encode!(report, pretty: true), [:exclusive])

    IO.inspect(
      %{
        new_components: length(missing),
        add: length(adds),
        remove: length(removes),
        mark_in_code: length(updates)
      }, label: "Plan")

    if opts[:apply] do
      {:ok, :ok} =
        Repo.transaction(
          fn ->
            known =
              Enum.reduce(missing, known, fn m, known ->
                parent_name = nearest_parent(m.name |> String.split(".") |> Enum.drop(-1), known)

                {:ok, c} =
                  Components.create_component(scope, %{
                    name: List.last(String.split(m.name, ".")),
                    module_name: m.name,
                    type: infer_type(m.content),
                    provenance: :discovered,
                    parent_component_id: parent_name && known[parent_name].id
                  })

                Map.put(known, m.name, c)
              end)

            Enum.each(missing, fn m ->
              {path, _} = Enum.find(modules, fn {_, candidate} -> candidate.name == m.name end)

              {:ok, _} =
                Files.upsert_file_metadata(scope, %{
                  path: path,
                  role: :implementation,
                  component_id: known[m.name].id,
                  size: byte_size(m.content),
                  fingerprint: :crypto.hash(:sha256, m.content) |> Base.encode16(case: :lower)
                })
            end)

            Enum.each(removes, fn d -> {:ok, _} = Components.delete_dependency(scope, d) end)

            Enum.each(adds, fn {a, b} ->
              {:ok, _} =
                Components.create_dependency(scope, %{
                  source_component_id: a,
                  target_component_id: b,
                  provenance: :discovered,
                  in_code: true
                })
            end)

            Enum.each(updates, fn d ->
              {:ok, _} = Components.update_dependency(scope, d, %{in_code: true})
            end)

            actual =
              Components.list_dependencies(scope)
              |> Enum.filter(
                &(MapSet.member?(covered, &1.source_component_id) and
                    MapSet.member?(covered, &1.target_component_id))
              )
              |> MapSet.new(&{&1.source_component_id, &1.target_component_id})

            true = actual == desired
            :ok
          end,
          timeout: :infinity
        )

      IO.puts("Applied and verified exact dependency equality for compiled components.")
    end
  end

  defp nearest_parent([], _known), do: nil

  defp nearest_parent(parts, known) do
    name = Enum.join(parts, ".")
    if Map.has_key?(known, name), do: name, else: nearest_parent(Enum.drop(parts, -1), known)
  end

  defp infer_type(content) do
    cond do
      ComponentExtract.ecto_schema?(content) -> "schema"
      String.contains?(content, "use CodeMySpecWeb, :live_view") -> "liveview"
      String.contains?(content, "use Phoenix.Component") -> "liveview_component"
      true -> "module"
    end
  end

  defp start_repo(database) do
    config =
      Application.get_env(:code_my_spec, Repo)
      |> Keyword.put(:database, database)
      |> Keyword.put(:pool_size, 2)
      |> Keyword.put(:log, false)

    Application.put_env(:code_my_spec, Repo, config)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

    {:ok, _} =
      Supervisor.start_link([{Phoenix.PubSub, name: CodeMySpec.PubSub}], strategy: :one_for_one)

    {:ok, _} = Repo.start_link()
    [[^database]] = Repo.query!("SELECT current_database()").rows
  end
end

Mix.Task.run("cms.reconcile_architecture", System.argv())
