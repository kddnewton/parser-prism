# frozen_string_literal: true

require "parser/current"

# First, opt in to every AST feature.
Parser::Builders::Default.modernize

# Modify the source map == check so that it doesn't check against the node
# itself so we don't get into a recursive loop.
Parser::Source::Map.prepend(
  Module.new {
    def ==(other)
      self.class == other.class &&
        (instance_variables - %i[@node]).map do |ivar|
          instance_variable_get(ivar) == other.instance_variable_get(ivar)
        end.reduce(:&)
    end
  }
)

# Next, ensure that we're comparing the nodes and also comparing the source
# ranges so that we're getting all of the necessary information.
Parser::AST::Node.prepend(
  Module.new {
    def ==(other)
      super && (location == other.location)
    end
  }
)

module Parser
  module YARP
    # Compare the ASTs between the translator and the whitequark/parser gem.
    def self.compare(filepath, source = nil)
      buffer = Source::Buffer.new(filepath, 1)
      buffer.source = source || File.read(filepath)

      parser = CurrentRuby.default_parser
      parser.diagnostics.consumer = ->(*) {}
      parser.diagnostics.all_errors_are_fatal = true

      expected = parser.parse(buffer)
      actual = parse(buffer)
      return true if expected == actual

      puts filepath
      queue = [[expected, actual]]

      while (left, right = queue.shift)
        if left.type != right.type
          puts "expected:"
          pp left

          puts "actual:"
          pp right

          return false
        end

        if left.location != right.location
          puts "expected:"
          pp left
          pp left.location

          puts "actual:"
          pp right
          pp right.location

          return false
        end

        left.children.zip(right.children).each do |left_child, right_child|
          queue << [left_child, right_child] if left_child.is_a?(Parser::AST::Node)
        end
      end

      false
    end
  end
end
