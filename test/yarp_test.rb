# frozen_string_literal: true

require "bundler/setup"
require "test/unit"

$:.unshift(File.expand_path("../lib", __dir__))
require "parser/yarp"
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

class YARPTest < Test::Unit::TestCase
  Dir[File.expand_path("fixtures/*.rb", __dir__)].each do |filepath|
    define_method("test_#{filepath}") { assert_parses(filepath) }
  end

  private

  def assert_parses(filepath)
    parser = Parser::CurrentRuby.default_parser
    parser.diagnostics.consumer = ->(*) {}
    parser.diagnostics.all_errors_are_fatal = true
  
    buffer = Parser::Source::Buffer.new(filepath, 1)
    buffer.source = File.read(filepath)
  
    expected = parser.parse(buffer)
    actual = Parser::YARP.parse(buffer)
    queue = [[expected, actual]]
  
    while (left, right = queue.shift)
      assert_equal(left.location, right.location)
  
      left.children.zip(right.children).each do |left_child, right_child|
        queue << [left_child, right_child] if left_child.is_a?(Parser::AST::Node)
      end
    end
  end
end
