<!-- cms:task type="ComponentSpec" component="Blog.Post" -->

Generate a Phoenix component spec for the following.
Project: some name
Project Description: 
Component Name: Post
Component Description: A test component
Type: schema

The implementation doesn't exist yet.
The tests don't exist yet.

Design Rules:


Document Specifications:
# Schema

Schema components represent Ecto schema entities that define data structures,
relationships, and validation rules for persistence in the database. Each schema
documents its fields, associations, validations, and database constraints.


## Required Sections

### Fields

Format:
- Use H2 heading
- Table format with columns: Field, Type, Required, Description, Constraints

Content:
- Only applicable for schemas and structs
- List all schema fields with their Ecto types
- Mark required fields clearly (Yes/No or Yes (auto) for auto-generated)
- Include constraints (length, format, references)

Examples:
- ## Fields
  | Field       | Type         | Required   | Description           | Constraints         |
  | ----------- | ------------ | ---------- | --------------------- | ------------------- |
  | id          | integer      | Yes (auto) | Primary key           | Auto-generated      |
  | name        | string       | Yes        | Name field            | Min: 1, Max: 255    |
  | foreign_id  | integer      | Yes        | Foreign key           | References table.id |


## Optional Sections

### Functions

Format:
- Use H2 heading
- Use H3 headers for each function in format: function_name/arity

Content:
- Document only PUBLIC functions (not private functions)
- Each function should include:
  * Brief description of what the function does
  * Elixir @spec in code block
  * **Process**: Step-by-step description of the function's logic
  * **Test Assertions**: List of test cases for this function

Examples:
- ## Functions
  ### build/1
  Apply dependency tree processing to all components.
  ```elixir
  @spec build([Component.t()]) :: [Component.t()]
  ```
  **Process**:
  1. Topologically sort components to process dependencies first
  2. Reduce over sorted components, building a map of processed components
  **Test Assertions**:
  - returns empty list for empty input
  - processes components in dependency order


### Dependencies

Format:
- Use H2 heading
- Simple bullet list of module names

Content:
- Each item must be a valid Elixir module name (PascalCase)
- No descriptions - just the module names
- Only include modules this module depends on

Examples:
- ## Dependencies
  - CodeMySpec.Components
  - CodeMySpec.Utils



Write the document to .code_my_spec/spec/blog/post.spec.md.
