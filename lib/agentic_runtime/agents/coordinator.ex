defmodule AgenticRuntime.Agents.Coordinator do
  @moduledoc """
  Coordinates agent lifecycle for conversation-centric agents.

  This module provides a single entry point for starting and stopping
  conversation-specific agents, handling agent_id generation, state
  loading, and race condition management.

  ## Usage

      # Start or resume a conversation agent. Pass the tenant scope from the
      # caller's session.
      # DISABLED (plan: valiant-twirling-crown): :filesystem_scope removed from example
      # filesystem_scope = {:user, current_scope.user.id}
      {:ok, session} = AgenticRuntime.Agents.Coordinator.start_conversation_session(
        conversation_id,
        scope: current_scope,
        # filesystem_scope: filesystem_scope,  # DISABLED
        factory_opts: [
          model_config: model_config,
          base_system_prompt: prompt,
          tools: tools
        ]
      )

      # Subscribe to agent events
      AgentServer.subscribe(session.agent_id)

      # Send message
      AgentServer.add_message(session.agent_id, message)

      # Stop agent (optional - agents auto-timeout)
      AgenticRuntime.Agents.Coordinator.stop_conversation_session(conversation_id)

  ## Configuration

  The PubSub server is resolved at runtime via `Application.get_env`:

      config :agentic_runtime,
        pubsub_name: MyApp.PubSub

  # DISABLED (plan: presence-shutdown-removal): :presence_module config no longer
  # consumed by the coordinator; presence-based shutdown is off — agents stop on
  # `inactivity_timeout` only. See `track_conversation_viewer/3` etc below.
  """

  alias AgenticRuntime.Agents.ServerAdapter
  alias AgenticRuntime.Agents.SupervisorAdapter
  alias Sagents.{State, AgentSupervisor}
  require Logger

  @pubsub_module Phoenix.PubSub

  # Default inactivity timeout (can be overridden per session)
  @inactivity_timeout_minutes 10

  @doc """
  Starts or resumes an agent session for a conversation.

  This function is idempotent — safe to call multiple times. If the agent is
  already running, returns the existing session.

  ## Options

  - `:filesystem_scope` — DISABLED (plan: valiant-twirling-crown). Accepted for backward
    compatibility but ignored — FileSystem middleware is commented out in `Factory`.
    Was: required filesystem scope tuple, e.g. `{:user, user_id}`.
  - `:scope` — Integrator-defined scope struct (see `AgenticRuntime.Scope`).
    In production this should come from the caller's session. `nil` is allowed
    for tests, admin scripts, or background jobs without a tenant context.
  - `:inactivity_timeout` — Milliseconds before the agent stops (default: 10 min).
  - `:tool_context` — Map of caller-supplied data passed to tool functions.
  - `:factory_opts` — Options passed through to `AgenticRuntime.Agents.Factory.create_agent/1`
    (e.g. `:model_config`, `:base_system_prompt`, `:tools`, `:fallback_models`).

  ## Returns

  - `{:ok, session}` — `%{agent_id, pid, conversation_id}` whether just started or already running
  - `{:error, reason}` — Failed to start
  """
  def start_conversation_session(conversation_id, opts \\ []) do
    # DISABLED (plan: valiant-twirling-crown): :filesystem_scope binding + propagation
    # commented; FileSystem middleware removed from factory. Opt accepted-but-ignored.
    # filesystem_scope = Keyword.get(opts, :filesystem_scope)
    #
    # case Keyword.fetch(opts, :filesystem_scope) do
    #   {:ok, scope_value} ->
    #     scope_value
    #
    #   :error ->
    #     raise ArgumentError, """
    #     Missing required :filesystem_scope option.
    #
    #     Please pass the filesystem scope when starting a session:
    #
    #         AgenticRuntime.Agents.Coordinator.start_conversation_session(
    #           conversation_id,
    #           filesystem_scope: {:user, user_id}
    #         )
    #     """
    # end

    agent_id = conversation_agent_id(conversation_id)

    case ServerAdapter.get_pid(agent_id) do
      nil ->
        # DISABLED (plan: valiant-twirling-crown): pass nil instead of filesystem_scope
        # do_start_session(conversation_id, agent_id, filesystem_scope, opts)
        do_start_session(conversation_id, agent_id, nil, opts)

      pid ->
        Logger.debug("Agent session already running for conversation #{conversation_id}")

        {:ok,
         %{
           agent_id: agent_id,
           pid: pid,
           conversation_id: conversation_id
         }}
    end
  end

  @doc """
  Stops an agent session for a conversation.

  Note: Agents automatically stop after inactivity timeout.
  Only call this for explicit cleanup (e.g., conversation archival).
  """
  def stop_conversation_session(conversation_id) do
    agent_id = conversation_agent_id(conversation_id)

    case ServerAdapter.get_pid(agent_id) do
      nil ->
        {:ok, :not_running}

      _pid ->
        ServerAdapter.stop(agent_id)
        {:ok, :stopped}
    end
  end

  @doc "Checks if an agent session is currently running."
  def session_running?(conversation_id) do
    agent_id = conversation_agent_id(conversation_id)
    ServerAdapter.get_pid(agent_id) != nil
  end

  @doc "Maps a conversation ID to an agent ID."
  def conversation_agent_id(conversation_id) do
    "conversation-#{conversation_id}"
  end

  @doc """
  Ensure the current process is subscribed to agent events for a conversation.

  Idempotent — safe to call multiple times.
  """
  def ensure_subscribed_to_conversation(conversation_id) do
    agent_id = conversation_agent_id(conversation_id)
    topic = agent_topic(agent_id)
    Sagents.PubSub.subscribe(@pubsub_module, pubsub_name(), topic)
  end

  @doc """
  Subscribe to agent events for a conversation without dedup.

  Prefer `ensure_subscribed_to_conversation/1` unless you specifically need
  raw subscription.
  """
  def subscribe_to_conversation(conversation_id) do
    agent_id = conversation_agent_id(conversation_id)
    topic = agent_topic(agent_id)
    Sagents.PubSub.raw_subscribe(@pubsub_module, pubsub_name(), topic)
  end

  @doc "Unsubscribe from agent events for a conversation."
  def unsubscribe_from_conversation(conversation_id) do
    agent_id = conversation_agent_id(conversation_id)
    topic = agent_topic(agent_id)
    Sagents.PubSub.unsubscribe(@pubsub_module, pubsub_name(), topic)
  end

  # DISABLED (plan: presence-shutdown-removal): presence helpers commented out.
  # Presence-based agent shutdown was removed in favor of `inactivity_timeout`-only.
  # No callers remain in agentic_runtime or Trento. Restore by uncommenting and
  # re-adding `presence_tracking` to `supervisor_config` in `do_start_session/4`.
  #
  # @doc """
  # Track a viewer's presence in a conversation. Phoenix.Presence cleans up
  # automatically when the tracked process terminates.
  # """
  # def track_conversation_viewer(conversation_id, viewer_id, metadata \\ %{}) do
  #   topic = presence_topic(conversation_id)
  #   full_metadata = Map.merge(%{joined_at: System.system_time(:second)}, metadata)
  #   Sagents.Presence.track(presence_module(), topic, viewer_id, full_metadata)
  # end
  #
  # @doc "Untrack a viewer's presence from a conversation."
  # def untrack_conversation_viewer(conversation_id, viewer_id) do
  #   topic = presence_topic(conversation_id)
  #   Sagents.Presence.untrack(presence_module(), topic, viewer_id)
  # end
  #
  # @doc "List all viewers currently present in a conversation."
  # def list_conversation_viewers(conversation_id) do
  #   topic = presence_topic(conversation_id)
  #   Sagents.Presence.list(presence_module(), topic)
  # end

  @doc "Get the PubSub topic for a conversation's agent."
  def conversation_topic(conversation_id) do
    agent_id = conversation_agent_id(conversation_id)
    agent_topic(agent_id)
  end

  @doc "Get the PubSub server name from application config."
  def pubsub_name do
    Application.get_env(:agentic_runtime, :pubsub_name)
  end

  # DISABLED (plan: presence-shutdown-removal): presence_module/0 unused after
  # presence helpers were commented out.
  #
  # @doc "Get the Presence module from application config."
  # def presence_module do
  #   Application.get_env(:agentic_runtime, :presence_module)
  # end

  # Private Functions

  defp agent_topic(agent_id), do: "agent_server:#{agent_id}"

  # DISABLED (plan: presence-shutdown-removal): only callsites were the now-commented
  # presence helpers above.
  # defp presence_topic(conversation_id), do: "conversation:#{conversation_id}"

  # DISABLED (plan: valiant-twirling-crown): _filesystem_scope param ignored;
  # log line dropped its filesystem_scope fragment; Keyword.put for :filesystem_scope removed.
  defp do_start_session(conversation_id, agent_id, _filesystem_scope, opts) do
    Logger.info("Starting agent session for conversation #{conversation_id}")
    # Logger.info(
    #   "Starting agent session for conversation #{conversation_id} with filesystem_scope #{inspect(filesystem_scope)}"
    # )

    factory_opts = Keyword.get(opts, :factory_opts, [])
    scope = Keyword.get(opts, :scope)
    tool_context = Keyword.get(opts, :tool_context, %{})

    # Sagents 0.7+ propagates :scope to persistence callbacks (arg #1) and to
    # tool `context.scope`. No need to stuff it into tool_context manually.
    merged_factory_opts =
      factory_opts
      |> Keyword.put(:agent_id, agent_id)
      # DISABLED (plan: valiant-twirling-crown): no longer propagate :filesystem_scope to factory
      # |> Keyword.put(:filesystem_scope, filesystem_scope)
      |> Keyword.put(:scope, scope)
      |> Keyword.put(:tool_context, tool_context)

    {:ok, agent} = AgenticRuntime.Agents.Factory.create_agent(merged_factory_opts)

    # Load or create state, scoped to the caller
    {:ok, state} = create_conversation_state(conversation_id, scope)

    inactivity_timeout =
      Keyword.get(opts, :inactivity_timeout, :timer.minutes(@inactivity_timeout_minutes))

    supervisor_name = AgentSupervisor.get_name(agent_id)

    # DISABLED (plan: presence-shutdown-removal): presence_tracking + presence_module
    # opts dropped from supervisor_config. Sagents.AgentServer treats absent
    # presence_config as nil and short-circuits maybe_shutdown_if_no_viewers/1, so
    # only the inactivity_timeout above can stop the agent.
    #
    # presence_tracking = [
    #   enabled: true,
    #   presence_module: presence_module(),
    #   topic: presence_topic(conversation_id)
    # ]

    supervisor_config = [
      agent_id: agent_id,
      name: supervisor_name,
      agent: agent,
      initial_state: state,
      pubsub: {@pubsub_module, pubsub_name()},
      debug_pubsub: {@pubsub_module, pubsub_name()},
      inactivity_timeout: inactivity_timeout,
      # DISABLED (plan: presence-shutdown-removal):
      # presence_tracking: presence_tracking,
      # presence_module: presence_module(),
      conversation_id: conversation_id,
      agent_persistence: AgenticRuntime.Agents.AgentPersistence,
      display_message_persistence: AgenticRuntime.Agents.DisplayMessagePersistence
    ]

    case SupervisorAdapter.start_agent_sync(supervisor_config) do
      {:ok, _supervisor_pid} ->
        pid = ServerAdapter.get_pid(agent_id)
        {:ok, %{agent_id: agent_id, pid: pid, conversation_id: conversation_id}}

      {:ok, _supervisor_pid, :already_started} ->
        pid = ServerAdapter.get_pid(agent_id)
        {:ok, %{agent_id: agent_id, pid: pid, conversation_id: conversation_id}}

      {:error, reason} ->
        Logger.error("Failed to start agent session: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp create_conversation_state(conversation_id, scope) do
    agent_id = conversation_agent_id(conversation_id)

    load_result =
      AgenticRuntime.Agents.AgentPersistence.load_state(scope, %{
        agent_id: agent_id,
        conversation_id: conversation_id
      })

    case load_result do
      {:ok, exported_state} ->
        Logger.info(
          "Found saved state for conversation #{conversation_id}, attempting to restore..."
        )

        nested_state = exported_state["state"]

        if is_nil(nested_state) do
          Logger.warning(
            "Exported state for conversation #{conversation_id} has no 'state' field, using fresh state"
          )

          {:ok, State.new!(%{})}
        else
          case State.from_serialized(agent_id, nested_state) do
            {:ok, state} ->
              Logger.info(
                "Successfully restored agent state for conversation #{conversation_id} with #{length(state.messages)} messages"
              )

              {:ok, state}

            {:error, reason} ->
              Logger.warning(
                "Failed to deserialize agent state for conversation #{conversation_id}: #{inspect(reason)}, using fresh state"
              )

              {:ok, State.new!(%{})}
          end
        end

      {:error, :not_found} ->
        Logger.info(
          "No saved state found for conversation #{conversation_id}, creating fresh state"
        )

        {:ok, State.new!(%{})}
    end
  end
end
