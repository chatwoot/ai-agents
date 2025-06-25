# Example of tool calling from MCP server

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "agents"

# This example demonstrates basic MCP client usage
# Prerequisites: npm install -g @modelcontextprotocol/server-filesystem

# Create an MCP client for a local filesystem server
FILESYSTEM_CLIENT = Agents::MCP::Client.new(
  name: "Filesystem",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", Dir.home]  # Use home directory instead of /tmp
)

begin
  puts "Connecting to filesystem MCP server..."
  FILESYSTEM_CLIENT.connect
  
  puts "Listing available tools..."
  tools = FILESYSTEM_CLIENT.list_tools
  puts "Found #{tools.count} tools"
  
  # Test a simple tool call
  if tools.any? { |t| t.name == "list_directory" }
    puts "\nTesting list_directory tool..."
    result = FILESYSTEM_CLIENT.call_tool("list_directory", { path: Dir.home })
    puts "Directory listing result: #{result}"
  end
  
  # Test read_file if available
  if tools.any? { |t| t.name == "read_file" }
    # Try to read a common file that likely exists
    test_files = [
      File.join(Dir.home, ".bashrc"),
      File.join(Dir.home, ".zshrc"), 
      File.join(Dir.home, ".profile")
    ]
    
    test_file = test_files.find { |f| File.exist?(f) }
    
    if test_file
      puts "\nTesting read_file tool with: #{test_file}"
      result = FILESYSTEM_CLIENT.call_tool("read_file", { path: test_file })
      puts "File read result: #{result.to_s[0..100]}#{'...' if result.to_s.length > 100}"
    else
      puts "\nSkipping read_file test - no suitable test files found"
    end
  end

rescue Agents::MCP::Error => e
  puts "MCP Error: #{e.message}"
  puts "Make sure you have the MCP filesystem server installed:"
  puts "npm install -g @modelcontextprotocol/server-filesystem"
rescue StandardError => e
  puts "Error: #{e.message}"
ensure
  FILESYSTEM_CLIENT&.disconnect if FILESYSTEM_CLIENT&.connected?
end

puts "\nBasic MCP example completed!"