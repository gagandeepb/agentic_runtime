defmodule AgenticRuntime.Mocks do
  @moduledoc """
  Central declaration of Mox mocks used across the agentic_runtime test suite.

  Defining the mocks inside a module compiled under `elixirc_paths(:test)` ensures
  the mock modules exist before `test_helper.exs` runs and before any test module
  references them as `AgenticRuntime.Agents.ServerAdapter.Mock` /
  `AgenticRuntime.Agents.SupervisorAdapter.Mock`.
  """
end

# Mox.defmock(AgenticRuntime.Agents.ServerAdapter.Mock,
#   for: AgenticRuntime.Agents.ServerAdapter
# )

# Mox.defmock(AgenticRuntime.Agents.SupervisorAdapter.Mock,
#   for: AgenticRuntime.Agents.SupervisorAdapter
# )
