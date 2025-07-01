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
      # @param content [String, Array<Hash>] Content from MCP response or simple string
      # @param is_error [Boolean] Whether this result represents an error
      def initialize(content, is_error: false)
        @content = if content.is_a?(String)
                     # Simple string content - wrap in structured format
                     [{ "type" => "text", "text" => content }]
                   else
                     # Structured content array
                     Array(content)
                   end
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

      # Create a ToolResult from an MCP server response
      #
      # @param response [Hash] The MCP server response
      # @return [ToolResult] A new ToolResult instance
      def self.from_mcp_response(response)
        return new("No response from MCP server") unless response

        if response.is_a?(Hash) && response["result"]
          # MCP server success response format
          result = response["result"]
          content = result["content"] || []
          is_error = result["isError"] || false

          new(content, is_error: is_error)
        elsif response.is_a?(Hash) && response["error"]
          # MCP server error response format
          error_msg = response["error"]["message"] || "Unknown error"
          error_content = [{ "type" => "text", "text" => error_msg }]

          new(error_content, is_error: true)
        elsif response.is_a?(Hash) && response["content"]
          # Direct content response (when transport strips the "result" wrapper)
          content = response["content"]

          new(content, is_error: false)
        else
          # Handle direct response or unexpected format
          content = response.is_a?(Array) ? response : [{ "type" => "text", "text" => response.to_s }]

          new(content, is_error: false)
        end
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

      # Extract content from MCP response content array
      #
      # @param content [Array, String] Content from MCP response
      # @return [String] Extracted text content
      def self.extract_content(content)
        if content.is_a?(Array)
          content.map do |item|
            if item.is_a?(Hash) && item["text"]
              item["text"]
            else
              item.to_s
            end
          end.join("\n")
        else
          content.to_s
        end
      end
    end
  end
end
