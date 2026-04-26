defmodule Mix.Tasks.GenerateDemo do
  use Boundary, classify_to: CodeMySpec

  @moduledoc """
  Generates demo Phoenix contexts with proper timing and automatic router injection.

  ## Usage

      mix generate_demo [commands_file] [options]

  ## Arguments

      commands_file       Path to file containing mix commands (default: demo_commands.txt)

  ## Options

      --delay SECONDS     Delay between commands in seconds (default: 1.2)

  ## Examples

      mix generate_demo
      mix generate_demo my_commands.txt
      mix generate_demo --delay 2.0
      mix generate_demo my_commands.txt --delay 2.0

  ## Commands File Format

  Each line should be a complete mix command. Multiline commands are supported using backslash:

      mix phx.gen.live Projects Project projects \
        name:string \
        description:text \
        status:string

      # Comments are ignored
      mix phx.gen.live Stories Story stories title:string project_id:references:projects

  """

  use Mix.Task
  require Logger

  @shortdoc "Generate demo contexts with router injection"

  @default_delay 0.2

  def run(args) do
    {opts, remaining_args, _} =
      OptionParser.parse(args,
        switches: [delay: :float],
        aliases: [d: :delay]
      )

    delay = Keyword.get(opts, :delay, @default_delay)
    commands_file = List.first(remaining_args) || "demo_commands.txt"

    Mix.shell().info("=== Requirements Generator Demo Creator ===")

    generate_from_file(commands_file, delay)
  end

  defp generate_from_file(commands_file, delay) do
    case read_commands_file(commands_file) do
      {:ok, commands} ->
        generate_demo_with_commands(commands, delay)

      {:error, reason} ->
        Mix.shell().error("Failed to read commands file '#{commands_file}': #{reason}")
        Mix.shell().info("Please create the commands file and try again.")
    end
  end

  defp read_commands_file(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        commands =
          content
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&(String.length(&1) > 0 and not String.starts_with?(&1, "#")))
          |> join_multiline_commands()

        {:ok, commands}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp join_multiline_commands(lines) do
    {commands, current_command} =
      Enum.reduce(lines, {[], ""}, fn line, {commands, accumulator} ->
        trimmed_line = String.trim(line)

        cond do
          String.ends_with?(trimmed_line, "\\") ->
            # This line continues, remove the backslash and accumulate
            cleaned_line = String.trim_trailing(trimmed_line, "\\") |> String.trim()

            new_accumulator =
              if accumulator == "", do: cleaned_line, else: "#{accumulator} #{cleaned_line}"

            {commands, new_accumulator}

          accumulator != "" ->
            # We're finishing a multiline command
            completed_command = "#{accumulator} #{trimmed_line}" |> String.trim()
            {[completed_command | commands], ""}

          true ->
            # Single line command
            {[trimmed_line | commands], ""}
        end
      end)

    # Handle case where file ends with a multiline command
    final_commands = if current_command != "", do: [current_command | commands], else: commands

    final_commands
    |> Enum.reverse()
    # Only keep actual mix commands, filter out malformed (too short)
    |> Enum.filter(&(String.contains?(&1, "mix ") and String.length(&1) > 10))
  end

  defp generate_demo_with_commands(commands, delay) do
    total = length(commands)

    Mix.shell().info("Total commands: #{total}")
    Mix.shell().info("Delay between commands: #{delay} seconds")
    Mix.shell().info("Estimated time: #{estimate_time(total, delay)}")
    Mix.shell().info("Starting generation...")

    route_injections = []

    results =
      commands
      |> Enum.with_index(1)
      |> Enum.reduce_while(route_injections, fn {command, index}, route_acc ->
        Mix.shell().info("[#{index}/#{total}] #{command}")

        case execute_command(command) do
          {:ok, output} ->
            Mix.shell().info("  → SUCCESS")

            # Extract routes from output
            new_routes = extract_routes_from_output(output)
            updated_routes = route_acc ++ new_routes

            # Wait before next command (except last)
            if index < total do
              Mix.shell().info("  → Waiting #{delay}s...")
              Process.sleep(trunc(delay * 1000))
            end

            {:cont, updated_routes}

          {:error, reason} ->
            Mix.shell().error("  → FAILED: #{inspect(reason)}")
            Mix.shell().error("Error details: #{reason}")
            {:halt, route_acc}
        end
      end)

    # Inject all collected routes at once
    if results != [] do
      inject_routes_to_router(results)
    end

    Mix.shell().info("\n=== Generation Complete ===")
    Mix.shell().info("Next steps:")
    Mix.shell().info("1. Run: mix ecto.migrate")
    Mix.shell().info("2. Run: mix ecto.seed (if you have seed files)")
    Mix.shell().info("3. Run: mix phx.server")
  end

  defp execute_command(command) do
    # Parse mix command
    args = String.split(command, " ")
    [_mix | task_parts] = args

    # Capture both stdout and stderr
    {output, exit_code} = System.cmd("mix", task_parts, stderr_to_stdout: true)

    case exit_code do
      0 -> {:ok, output}
      _ -> {:error, output}
    end
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  defp extract_routes_from_output(output) do
    # Look for the "Add the live routes" or "Add the routes" section
    case Regex.run(
           ~r/Add the (?:live )?routes to your browser scope.*?:\s*(.*?)(?:\s*Remember|\s*$)/s,
           output
         ) do
      [_full_match, routes_section] ->
        routes_section
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(
          &(String.length(&1) > 0 and
              String.starts_with?(&1, [
                "live ",
                "get ",
                "post ",
                "put ",
                "patch ",
                "delete ",
                "resources "
              ]))
        )

      _ ->
        # Fallback: look for any lines that look like routes
        output
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&Regex.match?(~r/^\s*(live|get|post|put|patch|delete|resources)\s+"/, &1))
        |> Enum.map(&String.trim/1)
    end
  end

  defp inject_routes_to_router([_ | _] = routes) do
    router_path = find_router_file()

    case File.read(router_path) do
      {:ok, content} ->
        updated_content = inject_routes_into_content(content, routes)

        case File.write(router_path, updated_content) do
          :ok ->
            Mix.shell().info("✓ Injected #{length(routes)} routes into #{router_path}")

          {:error, reason} ->
            Mix.shell().error("Failed to write router file: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.shell().error("Failed to read router file: #{inspect(reason)}")
        Mix.shell().info("Please manually add these routes:")
        Enum.each(routes, &Mix.shell().info("  #{&1}"))
    end
  end

  defp inject_routes_to_router([]), do: :ok

  defp find_router_file do
    # Standard Phoenix router location
    possible_paths = [
      "lib/*_web/router.ex",
      "lib/*/router.ex"
    ]

    found_path =
      possible_paths
      |> Enum.flat_map(&Path.wildcard/1)
      |> List.first()

    found_path || Mix.raise("Could not find router.ex file")
  end

  defp inject_routes_into_content(content, routes) do
    # Find the browser scope
    browser_scope_pattern =
      ~r/(scope "\/", \w+Web do\s*\n\s*pipe_through :browser\s*\n)(.*?)(\n\s*end)/s

    case Regex.run(browser_scope_pattern, content) do
      [full_match, scope_start, existing_routes, scope_end] ->
        # Format new routes with proper indentation
        formatted_routes = Enum.map_join(routes, "\n", &"    #{&1}")

        # Combine existing routes with new ones
        new_scope_content =
          "#{scope_start}#{existing_routes}\n\n    # Generated demo routes\n#{formatted_routes}#{scope_end}"

        String.replace(content, full_match, new_scope_content)

      _ ->
        Mix.shell().error("Could not find browser scope in router. Please manually add routes:")
        Enum.each(routes, &Mix.shell().info("  #{&1}"))
        content
    end
  end

  defp estimate_time(total, delay) do
    total_seconds = trunc(total * delay)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)
    "#{minutes}m #{seconds}s"
  end
end
