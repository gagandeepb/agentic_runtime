defmodule AgenticRuntime.AgentCase do
  @moduledoc """
  Test case for tests that exercise the agent supervision/server stack.

  Composes `AgenticRuntime.DataCase` (DB sandbox + factory imports) and adds
  Mox setup for the `ServerAdapter` and `SupervisorAdapter` boundaries:

    * `set_mox_from_context/1` — allows `expect/3` calls to be honoured from
      processes other than the test process (e.g. when the coordinator hands
      work off to another process).
    * `verify_on_exit!/1` — fails the test if any expectation set with
      `expect/3` was not satisfied.
  """

  use ExUnit.CaseTemplate

  import Mox

  using do
    quote do
      use AgenticRuntime.DataCase

      import Mox

      alias AgenticRuntime.Agents.ServerAdapter
      alias AgenticRuntime.Agents.SupervisorAdapter
    end
  end

  setup :set_mox_from_context
  setup :verify_on_exit!
end
