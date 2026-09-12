defmodule CodeMySpecSpex.ProjectBuilder do
  @moduledoc """
  Compose a plausible project in the in-memory filesystem, one piece at a time.

  ## What this is NOT

  **This does not reproduce what `cms.new` generates, and must not pretend to.**
  A fixture that claims to be the generator's output is wrong the first time
  the generator changes, and wrong silently — every spec keeps passing against
  a shape no customer has. For a claim *about* the generator, use
  `drill_working_directory`, which runs the real chain on real disk in ~0.4s.

  This builds a project that is *shaped like* a real one as far as the scanner
  is concerned: files the classifier recognises, in the paths it looks in, with
  content that parses. That is enough to make the graph move, which is what a
  spec about agent behaviour actually needs.

  ## What the scanner recognises

  Composed pieces land at paths `Scanner.classify/1` has a clause for. Anything
  else is unclassified, and an unclassified file never syncs — so a builder that
  wrote to a path nobody reads would produce a project that looks full and
  behaves empty.

  | Piece | Path | Classified as |
  |---|---|---|
  | `new/2` | `mix.exs` | `:mix_exs` |
  | `context/3` | `.code_my_spec/spec/<name>.spec.md` + `lib/<app>/<name>.ex` | spec + implementation |
  | `component/3` | `lib/<app>/<parent>/<name>.ex` | implementation |
  | `unit_test/2` | `test/<app>/<name>_test.exs` | test |
  | `spex/3` | `test/spex/<story>/<criterion>_spex.exs` | spex |

  ## Use

      project =
        ProjectBuilder.new(context.environment, app: "my_app")
        |> ProjectBuilder.context("Accounts")
        |> ProjectBuilder.component("Accounts", "User")
        |> ProjectBuilder.unit_test("Accounts")
        |> ProjectBuilder.write!()

      project.paths        # every path written, in order
      project.modules      # every module name defined

  Nothing is written until `write!/1`, so a spec can assemble the shape it
  wants and then observe the sync as a single event rather than a trickle —
  which matters, because the graph debounces and a trickle coalesces
  unpredictably.

  ## Making the graph notice

  Writing files changes nothing by itself. Pair this with
  `GraphSpexHelpers.watch_graph/1` and drive the sync the way an engineer
  would, then `settle_graph/1` before asserting.
  """

  alias CodeMySpec.Environments
  alias CodeMySpec.Paths

  defstruct env: nil, app: "my_app", pending: [], paths: [], modules: []

  @type t :: %__MODULE__{}

  @doc """
  Start a project: an app name and a `mix.exs` so the tree has a root.

  `mix.exs` is not decoration. `Scanner.classify/1` has a clause for it, the
  working-copy checks look for it, and a tree without one reads as "not a
  project" rather than as an empty one.
  """
  def new(env, opts \\ []) do
    app = Keyword.get(opts, :app, "my_app")

    %__MODULE__{env: env, app: app}
    |> put("mix.exs", mix_exs(app))
    |> put("lib/#{app}.ex", module_source(camelize(app), "The application root."))
    |> record_module(camelize(app))
  end

  @doc """
  A context: its spec and its implementation, the pair the graph joins on.

  Both halves are written because a spec without an implementation and an
  implementation without a spec are each a *different* state of the graph —
  meaningful states, but not this one. Use `spec_only/2` or `impl_only/3` when
  the gap is the point.
  """
  def context(%__MODULE__{} = b, name, opts \\ []) do
    module = context_module(b, name)

    b
    |> put(spec_path(name), spec_source(module, Keyword.get(opts, :functions, ["noop/0"])))
    |> put(impl_path(b, name), module_source(module, "#{name} context."))
    |> record_module(module)
  end

  @doc "A context's spec with no implementation behind it."
  def spec_only(%__MODULE__{} = b, name, opts \\ []) do
    module = context_module(b, name)

    b
    |> put(spec_path(name), spec_source(module, Keyword.get(opts, :functions, ["noop/0"])))
    |> record_module(module)
  end

  @doc "An implementation with no spec describing it."
  def impl_only(%__MODULE__{} = b, name, _opts \\ []) do
    module = context_module(b, name)

    b
    |> put(impl_path(b, name), module_source(module, "#{name} context."))
    |> record_module(module)
  end

  @doc "A child component under a context."
  def component(%__MODULE__{} = b, parent, name, _opts \\ []) do
    module = "#{context_module(b, parent)}.#{camelize(name)}"
    path = "lib/#{b.app}/#{underscore(parent)}/#{underscore(name)}.ex"

    b
    |> put(path, module_source(module, "#{name} under #{parent}."))
    |> record_module(module)
  end

  @doc "A unit test for a context."
  def unit_test(%__MODULE__{} = b, name, _opts \\ []) do
    module = context_module(b, name)
    put(b, "test/#{b.app}/#{underscore(name)}_test.exs", test_source(module))
  end

  @doc "A spex file under a story and criterion."
  def spex(%__MODULE__{} = b, story_id, criterion_id, _opts \\ []) do
    put(b, "test/spex/#{story_id}/criterion_#{criterion_id}_spex.exs", spex_source(story_id, criterion_id))
  end

  @doc "Write an arbitrary file into the project at an exact path."
  def file(%__MODULE__{} = b, path, content), do: put(b, path, content)

  @doc """
  Write everything composed so far into the environment.

  Returns `%{paths: [...], modules: [...], app: "..."}` — the paths in the
  order they were written, and every module name defined, so a spec can assert
  against a component without repeating the naming rules.
  """
  def write!(%__MODULE__{} = b) do
    for {path, content} <- Enum.reverse(b.pending) do
      :ok = Environments.write_file(b.env, path, content)
    end

    %{
      app: b.app,
      paths: b.pending |> Enum.reverse() |> Enum.map(&elem(&1, 0)),
      modules: Enum.reverse(b.modules)
    }
  end

  # -- internals --

  defp put(%__MODULE__{} = b, path, content), do: %{b | pending: [{path, content} | b.pending]}
  defp record_module(%__MODULE__{} = b, module), do: %{b | modules: [module | b.modules]}

  defp context_module(%__MODULE__{app: app}, name), do: "#{camelize(app)}.#{camelize(name)}"
  defp spec_path(name), do: Path.join(Paths.spec_dir(), "#{underscore(name)}.spec.md")
  defp impl_path(%__MODULE__{app: app}, name), do: "lib/#{app}/#{underscore(name)}.ex"

  # Dots separate modules; underscores inside a segment are word breaks. Split
  # on the former and let `Macro.camelize/1` handle the latter, so `my_app`
  # becomes `MyApp` rather than `My.App` — which named a module nobody has and
  # made every module assertion fail against a real-looking string.
  defp camelize(name) do
    name
    |> to_string()
    |> String.split(".", trim: true)
    |> Enum.map_join(".", &Macro.camelize/1)
  end

  defp underscore(name), do: name |> to_string() |> Macro.underscore() |> String.replace("/", "_")

  defp mix_exs(app) do
    """
    defmodule #{camelize(app)}.MixProject do
      use Mix.Project

      def project do
        [app: :#{app}, version: "0.1.0", elixir: "~> 1.18", deps: []]
      end

      def application, do: [extra_applications: [:logger]]
    end
    """
  end

  defp module_source(module, doc) do
    """
    defmodule #{module} do
      @moduledoc "#{doc}"

      @doc "Returns `:ok`."
      def noop, do: :ok
    end
    """
  end

  defp spec_source(module, functions) do
    function_blocks =
      Enum.map_join(functions, "\n", fn signature ->
        name = signature |> String.split("/") |> List.first()

        """
        ### #{signature}

        Returns `:ok`.

        ```elixir
        @spec #{name}() :: :ok
        ```
        """
      end)

    """
    # #{module}

    ## Type

    context

    Built by ProjectBuilder for a spec fixture.

    ## Functions

    #{function_blocks}
    ## Dependencies

    - None

    ## Components

    None.
    """
  end

  defp test_source(module) do
    """
    defmodule #{module}Test do
      use ExUnit.Case, async: true

      test "noop" do
        assert #{module}.noop() == :ok
      end
    end
    """
  end

  defp spex_source(story_id, criterion_id) do
    """
    defmodule CodeMySpecSpex.Story#{story_id}.Criterion#{criterion_id}Spex do
      use CodeMySpecSpex.Case, async: false

      spex "built by ProjectBuilder" do
        scenario "placeholder", context do
          given_ "a project exists", context do
            {:ok, context}
          end
        end
      end
    end
    """
  end
end
