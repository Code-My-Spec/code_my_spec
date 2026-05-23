defmodule CodeMySpecSpex.Story812.Criterion6521Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6521 — Rule 6: GA4 measurement ID lives only in server
  config.

  Codebase-grep assertion (no cassette): scans the repo for the GA4
  measurement-ID pattern (`G-` followed by 7+ uppercase
  alphanumerics) and confirms every match is in `config/*.exs` or
  `config/runtime.exs`. Any match in `lib/code_my_spec_web/components`,
  `lib/code_my_spec_web/controllers`, `assets/js`, or rendered HEEx
  signals the ID leaked outside server config.

  Driving spec — will FAIL until root.html.heex / app.js drop their
  hardcoded ID references. Pairs with 6517 / 6518 / 6520.
  """

  use CodeMySpecSpex.Case

  @ga_id_pattern ~r/G-[A-Z0-9]{7,}/
  @scan_paths ["lib/code_my_spec_web", "assets/js", "assets/css"]
  @allowed_paths ["config/", "priv/"]

  spex "GA4 measurement ID lives only in server config" do
    scenario "every G-* match outside server config is reported" do
      given_ "the repo as it ships", context do
        {:ok, context}
      end

      when_ "we scan the disallowed paths for the measurement-ID pattern", context do
        offenders =
          @scan_paths
          |> Enum.flat_map(&list_files/1)
          |> Enum.filter(&File.regular?/1)
          |> Enum.flat_map(&matches_in_file/1)
          |> Enum.reject(fn {path, _} ->
            Enum.any?(@allowed_paths, &String.starts_with?(path, &1))
          end)

        {:ok, Map.put(context, :offenders, offenders)}
      end

      then_ "no measurement ID matches appear outside server config", context do
        assert context.offenders == [],
               """
               GA4 measurement ID found outside server config:

               #{Enum.map_join(context.offenders, "\n", fn {path, match} -> "  #{path}: #{match}" end)}

               Move every match into config/*.exs (per-env) or config/runtime.exs.
               """

        {:ok, context}
      end
    end
  end

  defp list_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full = Path.join(dir, entry)

          cond do
            File.dir?(full) -> list_files(full)
            File.regular?(full) -> [full]
            true -> []
          end
        end)

      _ ->
        []
    end
  end

  defp matches_in_file(path) do
    case File.read(path) do
      {:ok, content} ->
        @ga_id_pattern
        |> Regex.scan(content)
        |> Enum.map(fn [match | _] -> {path, match} end)

      _ ->
        []
    end
  end
end
