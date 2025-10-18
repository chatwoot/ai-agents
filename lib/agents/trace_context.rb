# frozen_string_literal: true

module Agents
  # Holds trace metadata for a conversation or operation.
  # This context can be nested and merged to support hierarchical tracing.
  #
  # ## Usage
  #   context = TraceContext.new(
  #     user_id: "user_123",
  #     session_id: "session_abc",
  #     tags: ["support"],
  #     metadata: { tier: "premium" }
  #   )
  #
  # ## Merging
  # When contexts are nested, they merge intelligently:
  # - user_id and session_id: Child overrides parent
  # - tags: Concatenated
  # - metadata: Deep merged
  #
  class TraceContext
    attr_reader :user_id, :session_id, :trace_name, :tags, :metadata

    def initialize(user_id: nil, session_id: nil, trace_name: nil, tags: nil, metadata: nil)
      @user_id = user_id
      @session_id = session_id
      @trace_name = trace_name
      @tags = Array(tags)
      @metadata = metadata || {}
    end

    # Merge this context with another, creating a new context.
    # Child (other) context takes precedence for user_id, session_id, and trace_name.
    # Tags are concatenated. Metadata is deep merged.
    #
    # @param other [TraceContext] The context to merge with
    # @return [TraceContext] A new merged context
    def merge(other)
      TraceContext.new(
        user_id: other.user_id || @user_id,
        session_id: other.session_id || @session_id,
        trace_name: other.trace_name || @trace_name,
        tags: @tags + other.tags,
        metadata: deep_merge(@metadata, other.metadata)
      )
    end

    # Convert to OpenTelemetry attributes following semantic conventions.
    # Maps to both generic and Langfuse-specific attribute names.
    #
    # @return [Hash] OpenTelemetry attributes
    def to_otel_attributes
      attrs = {}

      # User and session identifiers (both generic and Langfuse conventions)
      attrs["user.id"] = @user_id if @user_id
      attrs["langfuse.user.id"] = @user_id if @user_id
      attrs["session.id"] = @session_id if @session_id
      attrs["langfuse.session.id"] = @session_id if @session_id

      # Tags (Langfuse convention)
      attrs["langfuse.trace.tags"] = @tags.join(",") unless @tags.empty?

      # Metadata (Langfuse convention - flattened with langfuse.trace.metadata prefix)
      @metadata.each do |key, value|
        attrs["langfuse.trace.metadata.#{key}"] = value.to_s
      end

      attrs
    end

    # Check if this context has any trace information
    # @return [Boolean]
    def empty?
      @user_id.nil? && @session_id.nil? && @trace_name.nil? && @tags.empty? && @metadata.empty?
    end

    private

    # Deep merge two hashes
    def deep_merge(hash1, hash2)
      hash1.merge(hash2) do |_key, old_val, new_val|
        if old_val.is_a?(Hash) && new_val.is_a?(Hash)
          deep_merge(old_val, new_val)
        else
          new_val
        end
      end
    end
  end
end
