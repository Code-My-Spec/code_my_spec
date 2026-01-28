defmodule CodeMySpec.Sessions.AgentTasks.WriteBddSpec do
  @moduledoc """
  Agent task for generating BDD specification files from acceptance criteria.

  Takes a story and criterion as input, generates a prompt with the Spex DSL guide
  and acceptance criteria context, and validates the generated spec file parses
  correctly and covers the criterion requirements.
  """

  alias CodeMySpec.BddSpecs
  alias CodeMySpec.BddSpecs.Parser

  @doc """
  Generate the prompt for Claude to create a BDD specification file using the Spex DSL.

  Extracts story and criterion from the session map and builds a comprehensive prompt
  including the Spex DSL syntax guide, story context, criterion requirements, and
  expected file path.
  """
  @spec command(term(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def command(_scope, session, _opts \\ []) do
    with {:ok, story} <- extract_story(session),
         {:ok, criterion} <- extract_criterion(session) do
      prompt = build_prompt(story, criterion)
      {:ok, prompt}
    end
  end

  @doc """
  Validate the generated BDD spec file parses correctly and covers the criterion.

  Checks that the spec file exists at the expected path, parses without syntax errors,
  contains at least one scenario, and scenarios contain Given/When/Then steps.
  """
  @spec evaluate(term(), map(), keyword()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()} | {:error, term()}
  def evaluate(_scope, session, _opts \\ []) do
    with {:ok, story} <- extract_story(session),
         {:ok, criterion} <- extract_criterion(session) do
      spec_path = get_full_spec_path(session, story, criterion)
      validate_spec_file(spec_path)
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp extract_story(%{story: %{id: _} = story}), do: {:ok, story}
  defp extract_story(_session), do: {:error, :story_missing}

  defp extract_criterion(%{criterion: %{id: _} = criterion}), do: {:ok, criterion}
  defp extract_criterion(_session), do: {:error, :criterion_missing}

  defp get_full_spec_path(session, story, criterion) do
    relative_path = BddSpecs.spec_file_path(story, criterion)
    working_dir = get_working_dir(session)
    Path.join(working_dir, relative_path)
  end

  defp get_working_dir(%{environment: %{cwd: cwd}}) when is_binary(cwd), do: cwd
  defp get_working_dir(%{environment: %{ref: %{working_dir: dir}}}), do: dir
  defp get_working_dir(_), do: File.cwd!()

  defp validate_spec_file(spec_path) do
    cond do
      not File.exists?(spec_path) ->
        {:error, :file_not_found}

      true ->
        case Parser.parse_file(spec_path) do
          {:ok, spec} ->
            validate_spec_content(spec)

          {:error, reason} ->
            {:ok, :invalid, "Parse error: #{inspect(reason)}"}
        end
    end
  end

  defp validate_spec_content(spec) do
    cond do
      Enum.empty?(spec.scenarios) ->
        {:ok, :invalid, "Spec must contain at least one scenario. No scenarios found."}

      not scenarios_have_steps?(spec.scenarios) ->
        {:ok, :invalid,
         "All scenarios must have Given/When/Then steps. Found scenario without steps."}

      true ->
        {:ok, :valid}
    end
  end

  defp scenarios_have_steps?(scenarios) do
    Enum.all?(scenarios, fn scenario ->
      has_steps =
        not Enum.empty?(scenario.given_steps) or
          not Enum.empty?(scenario.when_steps) or
          not Enum.empty?(scenario.then_steps)

      has_steps
    end)
  end

  defp build_prompt(story, criterion) do
    spec_path = BddSpecs.spec_file_path(story, criterion)

    """
    # Write BDD Specification

    Create a BDD specification file using the Spex DSL for the following acceptance criterion.

    ## Story Context

    **Title**: #{story.title}
    **Description**: #{story.description || "No description provided"}

    ## Acceptance Criterion

    #{criterion.description}

    ## Expected File Path

    Write the spec file to: `#{spec_path}`

    ## Spex DSL Syntax Guide

    Spex is a BDD framework for Elixir that uses Given/When/Then steps to describe behavior.

    ### Basic Structure

    ```elixir
    defmodule MyApp.FeatureNameSpex do
      use Spex

      spex "feature description" do
        scenario "scenario name" do
          given_ "precondition description", context do
            # Setup code - return {:ok, updated_context}
            {:ok, Map.put(context, :key, value)}
          end

          when_ "action description", context do
            # Action code - return {:ok, updated_context}
            {:ok, context}
          end

          then_ "expected outcome", context do
            # Assertion code - use assert, return :ok
            assert context.key == expected_value
            :ok
          end
        end
      end
    end
    ```

    ### Key Points

    1. **Module naming**: Use `MyApp.FeatureNameSpex` convention
    2. **spex macro**: Wraps all scenarios for a feature
    3. **scenario macro**: Defines a specific test case
    4. **given_ macro**: Sets up preconditions (note the underscore suffix)
    5. **when_ macro**: Performs the action being tested
    6. **then_ macro**: Asserts expected outcomes

    ### Step Return Values

    - `given_` and `when_` steps should return `{:ok, context}` with any updates
    - `then_` steps should use assertions and return `:ok`
    - Context is passed through each step in order

    ### Example

    ```elixir
    defmodule MyApp.UserRegistrationSpex do
      use Spex

      spex "user registration" do
        scenario "successful registration with valid data" do
          given_ "valid user data", context do
            {:ok, Map.put(context, :user_attrs, %{email: "test@example.com", password: "secure123"})}
          end

          when_ "user submits registration form", context do
            result = MyApp.Accounts.register_user(context.user_attrs)
            {:ok, Map.put(context, :result, result)}
          end

          then_ "user account is created", context do
            assert {:ok, user} = context.result
            assert user.email == "test@example.com"
            :ok
          end
        end
      end
    end
    ```

    ## Instructions

    1. Create a spec file at the path specified above
    2. Define scenarios that verify the acceptance criterion is met
    3. Include meaningful Given/When/Then steps
    4. Use descriptive step descriptions that explain what's happening
    5. Ensure the spec compiles and follows the Spex DSL syntax
    """
  end
end
