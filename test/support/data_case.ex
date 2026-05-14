defmodule AgenticRuntime.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias AgenticRuntime.TestRepo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import AgenticRuntime.DataCase
      import AgenticRuntime.Factory
    end
  end

  setup tags do
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(AgenticRuntime.TestRepo, shared: not tags[:async])

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
