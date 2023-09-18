# frozen_string_literal: true

require "parser"
require "rubocop"

module Parser
  class YARP < Base
    VERSION_3_3 = 24_00_17_15.33
  end
end

RuboCop::AST::ProcessedSource.prepend(
  Module.new do
    def parser_class(ruby_version)
      if ruby_version == Parser::YARP::VERSION_3_3
        require "parser/yarp"
        Parser::YARP
      else
        super
      end
    end
  end
)

known_rubies = RuboCop::TargetRuby.const_get(:KNOWN_RUBIES)
RuboCop::TargetRuby.send(:remove_const, :KNOWN_RUBIES)
RuboCop::TargetRuby::KNOWN_RUBIES = [*known_rubies, Parser::YARP::VERSION_3_3].freeze
