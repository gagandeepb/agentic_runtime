defprotocol AgenticRuntime.Scope do
  @moduledoc """
  Protocol that any host scope struct must implement to be threaded through
  AgenticRuntime persistence and tool callbacks.

  Sagents treats the scope as opaque (`term() | nil`) and propagates it to:
  - `AgenticRuntime.Agents.AgentPersistence` callbacks (arg #1)
  - `AgenticRuntime.Agents.DisplayMessagePersistence` callbacks (arg #1)
  - Tool functions via `context.scope`

  Library code calls `AgenticRuntime.Scope.owner_id/1` to derive the tenant
  identifier used for filtering DB queries. Hosts implement the protocol on
  their own scope module:

      defimpl AgenticRuntime.Scope, for: MyApp.Accounts.Scope do
        def owner_id(%MyApp.Accounts.Scope{user: %{id: id}}), do: id
      end

  `nil` is allowed for tests and admin scripts. Persistence functions that
  receive a `nil` scope return `{:error, :not_found}` for tenant-isolated
  reads/writes.
  """

  @doc """
  Returns the owner identifier (typically `user.id`) used to scope queries.
  """
  @spec owner_id(t()) :: term()
  def owner_id(scope)
end
