# frozen_string_literal: true

# Items represent the building blocks of a conversation in the agent system.
# Unlike simple string messages, items preserve the full context of interactions
# including tool calls, tool outputs, and handoffs. This allows the system to
# properly track conversation flow and prevent issues like handoff loops.

module Agents
  # Base class for all items generated during an agent run.
  # Items represent different types of interactions in a conversation,
  # such as user messages, assistant responses, tool calls, and tool outputs.
  #
  # @abstract Subclasses must implement {#to_input_item}
  class RunItem
    # @return [Agent, nil] The agent that generated this item
    attr_reader :agent
    
    # @return [Time] When this item was created
    attr_reader :timestamp

    # Initialize a new run item
    # @param agent [Agent, nil] The agent that generated this item
    def initialize(agent:)
      @agent = agent
      @timestamp = Time.now
    end

    # Convert this item to a format suitable for LLM input.
    # This method must be implemented by subclasses to return
    # a hash that can be passed to the chat model.
    #
    # @abstract
    # @return [Hash] Input-formatted representation of this item
    # @raise [NotImplementedError] If called on base class
    def to_input_item
      raise NotImplementedError, "Subclasses must implement to_input_item"
    end
  end

  # Represents a user message in the conversation.
  # User messages are the primary input that drives agent interactions.
  #
  # @example Creating a user message
  #   item = UserMessageItem.new(content: "What's the weather?")
  #   item.to_input_item
  #   # => { role: "user", content: "What's the weather?" }
  class UserMessageItem < RunItem
    # @return [String] The message content from the user
    attr_reader :content

    # Initialize a new user message item
    # @param content [String] The message content
    # @param agent [Agent, nil] The agent context (usually nil for user messages)
    def initialize(content:, agent: nil)
      super(agent: agent)
      @content = content
    end

    # Convert to LLM input format
    # @return [Hash{Symbol => String}] Hash with :role and :content
    def to_input_item
      { role: "user", content: @content }
    end
  end

  # Represents an assistant message containing actual conversational content.
  # This is used for meaningful responses from agents, not for system messages
  # like handoff acknowledgments.
  #
  # @example Creating an assistant message
  #   item = AssistantMessageItem.new(
  #     content: "The weather is sunny today!",
  #     agent: weather_agent
  #   )
  class AssistantMessageItem < RunItem
    # @return [String] The response content from the assistant
    attr_reader :content

    # Initialize a new assistant message item
    # @param content [String] The message content
    # @param agent [Agent] The agent that generated this response
    def initialize(content:, agent:)
      super(agent: agent)
      @content = content
    end

    # Convert to LLM input format
    # @return [Hash{Symbol => String}] Hash with :role and :content
    def to_input_item
      { role: "assistant", content: @content }
    end
  end

  # Represents a tool call made by an agent, including handoff requests.
  # Tool calls are function invocations that the agent wants to execute.
  #
  # @example Creating a tool call
  #   item = ToolCallItem.new(
  #     tool_name: "get_weather",
  #     arguments: { location: "San Francisco" },
  #     agent: weather_agent
  #   )
  #
  # @example Creating a handoff call
  #   item = ToolCallItem.new(
  #     tool_name: "transfer_to_support_agent",
  #     arguments: { reason: "Technical issue" },
  #     agent: triage_agent
  #   )
  class ToolCallItem < RunItem
    # @return [String] The name of the tool being called
    attr_reader :tool_name
    
    # @return [Hash] Arguments passed to the tool
    attr_reader :arguments
    
    # @return [String] Unique identifier for this tool call
    attr_reader :call_id

    # Initialize a new tool call item
    # @param tool_name [String] Name of the tool to call
    # @param arguments [Hash] Arguments for the tool (default: {})
    # @param call_id [String, nil] Unique ID for this call (auto-generated if nil)
    # @param agent [Agent] The agent making this tool call
    def initialize(tool_name:, arguments: {}, call_id: nil, agent:)
      super(agent: agent)
      @tool_name = tool_name
      @arguments = arguments
      @call_id = call_id || SecureRandom.uuid
    end

    # Convert to LLM input format with tool call structure
    # @return [Hash] Hash with :role and :tool_calls array
    def to_input_item
      {
        role: "assistant",
        tool_calls: [{
          id: @call_id,
          type: "function",
          function: {
            name: @tool_name,
            arguments: @arguments.to_json
          }
        }]
      }
    end
  end

  # Represents the output from a tool execution.
  # Tool outputs are the results returned after a tool call is executed.
  #
  # @example Creating a tool output
  #   item = ToolOutputItem.new(
  #     tool_call_id: "call_123",
  #     output: "Temperature is 72°F",
  #     agent: weather_agent
  #   )
  class ToolOutputItem < RunItem
    # @return [String] ID of the tool call this output corresponds to
    attr_reader :tool_call_id
    
    # @return [Object] The output from the tool execution
    attr_reader :output

    # Initialize a new tool output item
    # @param tool_call_id [String] ID of the corresponding tool call
    # @param output [Object] The tool's output (will be converted to string)
    # @param agent [Agent] The agent that executed this tool
    def initialize(tool_call_id:, output:, agent:)
      super(agent: agent)
      @tool_call_id = tool_call_id
      @output = output
    end

    # Convert to LLM input format
    # @return [Hash] Hash with :role, :tool_call_id, and :content
    def to_input_item
      {
        role: "tool",
        tool_call_id: @tool_call_id,
        content: @output.to_s
      }
    end
  end

  # Represents a handoff acknowledgment between agents.
  # This is a specialized tool output that tracks agent transitions.
  #
  # @example Creating a handoff output
  #   item = HandoffOutputItem.new(
  #     tool_call_id: "call_456",
  #     output: "Transferring to Support Agent...",
  #     source_agent: triage_agent,
  #     target_agent: support_agent,
  #     agent: triage_agent
  #   )
  class HandoffOutputItem < ToolOutputItem
    # @return [Agent] The agent initiating the handoff
    attr_reader :source_agent
    
    # @return [Agent, Class] The agent or agent class receiving the handoff
    attr_reader :target_agent

    # Initialize a new handoff output item
    # @param source_agent [Agent] The agent initiating the handoff
    # @param target_agent [Agent, Class] The target agent or agent class
    # @param kwargs [Hash] Additional arguments passed to parent class
    def initialize(source_agent:, target_agent:, **kwargs)
      super(**kwargs)
      @source_agent = source_agent
      @target_agent = target_agent
    end

    # Handoff outputs should NOT be included in conversation history
    # They are system-level routing information, not conversational content
    # @return [nil] Always returns nil to indicate this should be filtered out
    def to_input_item
      nil
    end
  end
end