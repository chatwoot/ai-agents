# frozen_string_literal: true

module Agents
  module MCP
    # Represents the result of an MCP tool call, encapsulating the response content
    # and metadata returned by the MCP server. This class handles complex responses
    # that may contain multiple content parts (text, images, etc.) and provides
    # convenient methods for accessing and converting the result.
    #
    # @example Simple text result
    #   result = ToolResult.new(
    #     content: [{"type" => "text", "text" => "Hello, world!"}],
    #     is_error: false
    #   )
    #   result.to_s # => "Hello, world!"
    #
    # @example Error result
    #   result = ToolResult.new(
    #     content: [{"type" => "text", "text" => "File not found"}],
    #     is_error: true
    #   )
    #   result.error? # => true
    class ToolResult
      attr_reader :content, :is_error

      # Initialize a new ToolResult
      #
      # @param content [Array<Hash>] Array of content parts from MCP response
      # @param is_error [Boolean] Whether this result represents an error
      def initialize(content:, is_error: false)
        @content = Array(content)
        @is_error = is_error
      end

      # Check if this result represents an error
      #
      # @return [Boolean] True if this is an error result
      def error?
        @is_error
      end

      # Check if this result represents a success
      #
      # @return [Boolean] True if this is a successful result
      def success?
        !@is_error
      end

      # Convert the result to a string representation
      # Combines all text content parts into a single string
      #
      # @return [String] String representation of the result
      def to_s
        text_parts = @content.select { |part| part["type"] == "text" }
        if text_parts.empty?
          # If no text parts, return JSON representation
          @content.to_json
        else
          text_parts.map { |part| part["text"] }.join("\n")
        end
      end

      # Convert the result to JSON
      #
      # @return [String] JSON representation of the complete result
      def to_json(*args)
        {
          content: @content,
          isError: @is_error
        }.to_json(*args)
      end

      # Get all text content from the result
      #
      # @return [Array<String>] Array of text content strings
      def text_content
        @content.select { |part| part["type"] == "text" }
                .map { |part| part["text"] }
      end

      # Get the first text content part
      #
      # @return [String, nil] First text content or nil if none exists
      def first_text
        text_part = @content.find { |part| part["type"] == "text" }
        text_part ? text_part["text"] : nil
      end

      # Check if result contains any text content
      #
      # @return [Boolean] True if result has text content
      def has_text?
        @content.any? { |part| part["type"] == "text" }
      end

      # Get all image content from the result
      #
      # @return [Array<Hash>] Array of image content parts
      def image_content
        @content.select { |part| part["type"] == "image" }
      end

      # Check if result contains any image content
      #
      # @return [Boolean] True if result has image content
      def has_images?
        @content.any? { |part| part["type"] == "image" }
      end

      # Create a ToolResult from a raw MCP server response
      #
      # @param response [Hash] Raw response from MCP server
      # @return [ToolResult] New ToolResult instance
      def self.from_mcp_response(response)
        result = response["result"] || {}
        content = result["content"] || []
        is_error = result["isError"] || false

        new(content: content, is_error: is_error)
      end
    end
  end
end