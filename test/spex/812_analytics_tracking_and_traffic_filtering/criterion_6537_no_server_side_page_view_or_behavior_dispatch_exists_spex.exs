defmodule CodeMySpecSpex.Story812.Criterion6537Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6537 — Rule 4 (hybrid): No server-side page_view or
  behavior dispatch exists.

  Hybrid design: page_view and all browser behavior events
  (install_command_copy, view_register_page, onboarding_panel_viewed,
  install_step_copied, deep_content_read) are handled by gtag.js on the
  client. The server must NOT fire these events via the Measurement
  Protocol, and the browser-to-server ingestion route must not exist.

  This criterion is a structural guard — if a refactor re-adds a
  server-side page_view plug, re-introduces Analytics.dispatch calls
  for browser-behavior events, or re-creates the deleted browser
  analytics ingestion route/controller, it flags immediately.

  Assertions:
  1. No plug module in lib/ dispatches :page_view via Analytics.dispatch.
  2. The router does not pipe through a PageView plug.
  3. No Analytics.dispatch(:page_view, ...) call exists anywhere in lib/.
  4. No file under lib/ references the string "/api/browser/analytics/event"
     (the deleted ingestion route that used to accept POSTs from the browser).
  5. AnalyticsEventController is not defined (the module was deleted when
     the route was removed).

  Codebase-grep pattern. Fails on any re-introduction of server-side
  page_view, behavior event dispatch, or the deleted ingestion route.
  """

  use CodeMySpecSpex.Case

  @lib_dir "lib"
  @router_path "lib/code_my_spec_web/router.ex"

  spex "No server-side page_view or behavior dispatch exists" do
    scenario "lib/ contains no Analytics.dispatch(:page_view, ...) call" do
      given_ "all Elixir source files under lib/", context do
        files = list_ex_files(@lib_dir)
        {:ok, Map.put(context, :ex_files, files)}
      end

      when_ "we scan for Analytics.dispatch(:page_view, ...)", context do
        hits =
          Enum.filter(context.ex_files, fn {_path, content} ->
            Regex.match?(~r/Analytics\.dispatch\(\s*:page_view/, content)
          end)
          |> Enum.map(&elem(&1, 0))

        {:ok, Map.put(context, :page_view_hits, hits)}
      end

      then_ "no file dispatches :page_view server-side", context do
        assert context.page_view_hits == [],
               """
               Found Analytics.dispatch(:page_view, ...) in:

                 #{Enum.join(context.page_view_hits, "\n  ")}

               In the hybrid design page_view is a gtag browser event — remove the server-side dispatch.
               """

        {:ok, context}
      end
    end

    scenario "lib/ contains no PageView plug wired into the router pipeline" do
      given_ "the router source", context do
        content = File.read!(@router_path)
        {:ok, Map.put(context, :router, content)}
      end

      when_ "we scan for a PageView plug reference", context do
        {:ok, context}
      end

      then_ "the router does not plug a PageView analytics module", context do
        refute context.router =~ ~r/PageView|page_view.*plug|plug.*page_view/i,
               "expected the router to have no PageView plug — page_view is a gtag browser event in the hybrid design"

        {:ok, context}
      end
    end

    scenario "behavior events (install_command_copy via Analytics.dispatch) are absent from lib/" do
      given_ "all Elixir source files under lib/", context do
        files = list_ex_files(@lib_dir)
        {:ok, Map.put(context, :ex_files, files)}
      end

      when_ "we scan for server-side dispatch of browser behavior events", context do
        # These events are now browser-only (gtag). Any Analytics.dispatch
        # call for them is a regression. The conversion events (sign_up,
        # registration_email_sent, first_cli_connect) are intentionally
        # EXCLUDED from this check — they remain server-side MP events.
        browser_only_events = [
          :install_command_copy,
          :view_register_page,
          :onboarding_panel_viewed,
          :install_step_copied
        ]

        hits =
          Enum.flat_map(browser_only_events, fn event ->
            pattern = ~r/Analytics\.dispatch\(\s*:#{event}/

            Enum.filter(context.ex_files, fn {_path, content} ->
              Regex.match?(pattern, content)
            end)
            |> Enum.map(fn {path, _} -> "#{path} (#{event})" end)
          end)

        {:ok, Map.put(context, :behavior_hits, hits)}
      end

      then_ "no server-side Analytics.dispatch for browser behavior events remains", context do
        assert context.behavior_hits == [],
               """
               Found server-side Analytics.dispatch for browser-behavior events:

                 #{Enum.join(context.behavior_hits, "\n  ")}

               These events are handled by gtag in the hybrid design.
               Remove the server-side dispatch calls.
               """

        {:ok, context}
      end
    end

    scenario "no file under lib/ references the deleted /api/browser/analytics/event route" do
      given_ "all source files under lib/ (ex, heex, js)", context do
        files = list_all_source_files(@lib_dir)
        {:ok, Map.put(context, :source_files, files)}
      end

      when_ "we scan for the deleted browser analytics ingestion route path", context do
        hits =
          Enum.filter(context.source_files, fn {_path, content} ->
            String.contains?(content, "/api/browser/analytics/event")
          end)
          |> Enum.map(&elem(&1, 0))

        {:ok, Map.put(context, :route_hits, hits)}
      end

      then_ "no file references the deleted ingestion route", context do
        assert context.route_hits == [],
               """
               Found references to the deleted /api/browser/analytics/event route in:

                 #{Enum.join(context.route_hits, "\n  ")}

               Migrate these callers to gtag('event', ...) — the browser ingestion route
               was removed in the hybrid design.
               """

        {:ok, context}
      end
    end

    scenario "AnalyticsEventController is not defined anywhere in lib/" do
      given_ "all Elixir source files under lib/", context do
        files = list_ex_files(@lib_dir)
        {:ok, Map.put(context, :ex_files, files)}
      end

      when_ "we scan for AnalyticsEventController definitions", context do
        hits =
          Enum.filter(context.ex_files, fn {_path, content} ->
            String.contains?(content, "AnalyticsEventController")
          end)
          |> Enum.map(&elem(&1, 0))

        {:ok, Map.put(context, :controller_hits, hits)}
      end

      then_ "AnalyticsEventController is not defined", context do
        assert context.controller_hits == [],
               """
               Found AnalyticsEventController referenced in:

                 #{Enum.join(context.controller_hits, "\n  ")}

               The controller was deleted when the browser analytics ingestion route was
               removed. Remove any remaining references.
               """

        {:ok, context}
      end
    end
  end

  @source_extensions [".ex", ".heex", ".js"]

  # Recursively collects all .ex files under dir with their content.
  defp list_ex_files(dir), do: list_source_files(dir, [".ex"])

  # Recursively collects all source files (.ex, .heex, .js) under dir with their content.
  defp list_all_source_files(dir), do: list_source_files(dir, @source_extensions)

  defp list_source_files(dir, extensions) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full = Path.join(dir, entry)

          cond do
            File.dir?(full) -> list_source_files(full, extensions)
            File.regular?(full) and Enum.any?(extensions, &String.ends_with?(full, &1)) ->
              case File.read(full) do
                {:ok, content} -> [{full, content}]
                _ -> []
              end
            true -> []
          end
        end)

      _ ->
        []
    end
  end
end
