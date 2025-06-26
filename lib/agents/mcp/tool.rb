# frozen_string_literal: true

module Agents
  module MCP
    # Dynamic tool class that represents tools provided by MCP servers.
    # These tools are generated at runtime based on the tool definitions
    # returned by the MCP server, creating a seamless interface between
    # the agent system and external MCP capabilities.
    #
    # Tools are created dynamically by parsing the MCP server's tool schema
    # and generating appropriate Ruby classes with proper parameter definitions.
    #
    # @example Usage (typically handled automatically by MCP::Client)
    #   tool_data = {
    #     "name" => "read_file",
    #     "description" => "Read the contents of a file",
    #     "inputSchema" => {
    #       "type" => "object",
    #       "properties" => {
    #         "path" => { "type" => "string", "description" => "File path" }
    #       },
    #       "required" => ["path"]
    #     }
    #   }
    #   
    #   tool = Tool.create_from_mcp_data(tool_data, client: mcp_client)
    #   # Tool can now be used like any other Agents::Tool
    class Tool < Agents::Tool
      attr_reader :mcp_client, :mcp_tool_name

      # Create a dynamic tool instance from MCP server tool data
      #
      # @param tool_data [Hash] Tool definition from MCP server
      # @param client [Agents::MCP::Client] The MCP client to use for calls
      # @return [Agents::MCP::Tool] New tool instance
      # @raise [ProtocolError] If tool schema is invalid
      def self.create_from_mcp_data(tool_data, client:)
        tool_name = tool_data["name"]
        tool_description = tool_data["description"] || "MCP tool #{tool_name}"
        input_schema = tool_data["inputSchema"] || {}

        raise ProtocolError, "Tool missing name" unless tool_name
        raise ProtocolError, "Invalid input schema" unless input_schema.is_a?(Hash)

        # Create dynamic tool class
        tool_class = Class.new(self) do
          # Set tool metadata
          description tool_description

          # Define parameters from schema
          properties = input_schema["properties"] || {}
          required_params = Set.new(input_schema["required"] || [])

          properties.each do |param_name, param_def|
            param_type = map_json_type_to_ruby(param_def["type"])
            param_desc = param_def["description"] || ""
            is_required = required_params.include?(param_name)

            param param_name.to_sym, type: param_type, desc: param_desc, required: is_required
          end

          # Store client and tool name for perform method
          define_method :initialize do
            @mcp_client = client
            @mcp_tool_name = tool_name
          end

          # Define the perform method that calls the MCP server
          define_method :perform do |tool_context, **args|
            # Call the MCP server with the provided arguments
            begin
              result = @mcp_client.call_tool(@mcp_tool_name, args)
              
              # Return result based on type
              if result.is_a?(ToolResult)
                # If it's already a ToolResult, convert to string for LLM
                result.to_s
              else
                # If it's a simple value, return as-is
                result.to_s
              end
            rescue => e
              "Error calling MCP tool #{@mcp_tool_name}: #{e.message}"
            end
          end

          # Override the name method to provide the MCP tool name
          define_singleton_method :name do
            tool_name
          end
          
          # Also provide a debug name
          define_method :inspect do
            "#<MCPTool(#{tool_name}):#{object_id}>"
          end
        end

        # Create and return instance
        tool_class.new
      end

      private

      # Map JSON schema types to Ruby types for RubyLLM
      #
      # @param json_type [String] JSON schema type
      # @return [Class] Corresponding Ruby type class
      def self.map_json_type_to_ruby(json_type)
        case json_type
        when "string" then String
        when "integer" then Integer
        when "number" then Float
        when "boolean" then TrueClass
        when "array" then Array
        when "object" then Hash
        else String # Default to String for unknown types
        end
      end
    end
  end
end